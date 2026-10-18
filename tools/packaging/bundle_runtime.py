#!/usr/bin/env python3
"""Bundle the RDP engine and its shared libraries at BUILD time, never at login.

Linux also includes linked Flutter/GTK/plugin libraries and a private ELF loader.
macOS uses Contents/MacOS and Contents/Frameworks, rewriting non-system dylibs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import ssl

REPO = Path(__file__).resolve().parents[2]


def run(args, **kwargs):
    result = subprocess.run([str(arg) for arg in args], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr or result.stdout}")
    return result.stdout


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def copy_file(source, target):
    source, target = Path(source), Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if digest(source) != digest(target):
            raise RuntimeError(f"Conflicting bundled library: {target.name}")
    else:
        shutil.copy2(source, target, follow_symlinks=True)
    target.chmod(target.stat().st_mode | 0o200)


def elf_dependencies(binary):
    output = run(['ldd', binary])
    if 'not found' in output:
        raise RuntimeError(f"Unresolved libraries for {binary.name}:\n{output}")
    dependencies = []
    for line in output.splitlines():
        match = re.search(r'=>\s+(/.*?)\s+\(', line)
        if not match:
            match = re.match(r'\s*(/.*?)\s+\(', line)
        if match:
            dependencies.append(Path(match[1]))
    return dependencies


def elf_interpreter(binary):
    output = run(['readelf', '-l', binary])
    match = re.search(r'Requesting program interpreter:\s*([^\]]+)', output)
    if not match:
        raise RuntimeError(f"No ELF interpreter found for {binary}")
    return Path(match[1].strip())


def is_elf(path):
    return path.is_file() and path.open('rb').read(4) == b'\x7fELF'


def available_source(explicit, system):
    if explicit:
        path = Path(explicit).expanduser().resolve()
        if not path.is_file():
            raise RuntimeError(f"RDP build input does not exist: {path}")
        return path
    names = ['sdl-freerdp', 'sdl-freerdp3'] if system == 'macos' else ['xfreerdp3', 'xfreerdp', 'sdl-freerdp', 'sdl-freerdp3']
    for name in names:
        found = shutil.which(name)
        if found:
            return Path(found).resolve()
    if system == 'linux':
        local = Path.home() / '.local/share/remina/engines/freerdp/bin/xfreerdp'
        if local.is_file():
            return local
    raise RuntimeError('Build requires FreeRDP 3 as an INPUT. Set REMINA_FREERDP_SOURCE or install it on the build machine. The finished application will include it.')


def licenses(destination, native_files=()):
    destination.mkdir(parents=True, exist_ok=True)
    if sys.platform.startswith('linux'):
        # Resolve ownership only for the binaries/libraries actually included.
        queries = [str(path) for path in native_files]
        result = subprocess.run(['dpkg-query', '-S', *queries], text=True, capture_output=True) if queries else None
        packages = {'libfreerdp3-3', 'libfreerdp-client3-3', 'libwinpr3-3'}
        if result:
            for line in result.stdout.splitlines():
                if ': ' in line:
                    packages.add(line.split(': ', 1)[0].split(':')[0])
        for package in packages:
            entry = Path('/usr/share/doc') / package / 'copyright'
            if entry.is_file():
                shutil.copy2(entry, destination / f'{package}.txt')
    else:
        # Homebrew stores installed formula license notices in the keg.
        for base in [Path('/opt/homebrew/Cellar'), Path('/usr/local/Cellar')]:
            if not base.exists():
                continue
            for entry in base.glob('*/*/LICENSE*'):
                if entry.is_file():
                    shutil.copy2(entry, destination / f'{entry.parent.parent.name}-{entry.name}.txt')
        for entry in (REPO / 'third_party/licenses').glob('*'):
            if entry.is_file():
                shutil.copy2(entry, destination / entry.name)


def manifest(root, target, system, version):
    target.parent.mkdir(parents=True, exist_ok=True)
    entries = []
    for path in sorted(root.rglob('*')):
        if path.is_file() and path != target and not path.is_symlink():
            entries.append({'path': str(path.relative_to(root)), 'sha256': digest(path)})
    target.write_text(json.dumps({'platform': system, 'architecture': platform.machine(),
        'freerdp_version': version.strip(), 'files': entries}, indent=2) + '\n')


def linux_launcher(target, binary, loader, library_dir, graphics=False):
    # No PATH lookup, installation prefix, or user engine directory at runtime.
    relative_binary = os.path.relpath(binary, target.parent)
    relative_loader = os.path.relpath(loader, target.parent)
    relative_lib = os.path.relpath(library_dir, target.parent)
    graphics_environment = ''
    if graphics:
        graphics_environment = (
            'export REMINA_BUNDLE_DIR="$REMINA_DIR"\n'
            'export __GLX_VENDOR_LIBRARY_NAME=mesa\n'
            'export GSETTINGS_SCHEMA_DIR="$REMINA_DIR/runtime/schemas"\n'
            'export GSETTINGS_BACKEND=memory\n'
            'export FONTCONFIG_FILE="$REMINA_DIR/runtime/fonts.conf"\n'
            'export __EGL_VENDOR_LIBRARY_FILENAMES="$REMINA_DIR/runtime/egl.json"\n'
            'export LIBGL_DRIVERS_PATH="$REMINA_DIR/lib/dri"\n'
        )
    if not graphics:
        graphics_environment = (
            'export SSL_CERT_FILE="$REMINA_DIR/../share/cacert.pem"\n'
            'export OPENSSL_MODULES="$REMINA_DIR/../lib/ossl-modules"\n'
        )
    target.write_text('#!/bin/sh\nset -eu\n' 
        'REMINA_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
        'unset LD_PRELOAD LD_LIBRARY_PATH\n'
        + graphics_environment + f'exec "$REMINA_DIR/{relative_loader}" --inhibit-cache '
        f'--library-path "$REMINA_DIR/{relative_lib}" '
        f'"$REMINA_DIR/{relative_binary}" "$@"\n')
    target.chmod(0o755)


def linux_bundle(root, source):
    version = run([source, '/version'])
    if not re.search(r'\b3\.\d+', version):
        raise RuntimeError('Only FreeRDP 3 is supported')
    engine = root / 'rdp'
    if engine.exists():
        shutil.rmtree(engine)
    binary = engine / 'bin/freerdp'
    copy_file(source, binary)
    library_dir = engine / 'lib'
    dependencies = elf_dependencies(source)
    loader = elf_interpreter(source)
    for dependency in [*dependencies, loader]:
        copy_file(dependency, library_dir / dependency.name)
    for crypto in [p for p in dependencies if p.name.startswith('libcrypto')]:
        for module in (crypto.parent / 'ossl-modules').glob('*.so'):
            copy_file(module, library_dir / 'ossl-modules' / module.name)
            for dependency in elf_dependencies(module):
                copy_file(dependency, library_dir / dependency.name)
    ca_bundle = ssl.get_default_verify_paths().cafile
    if not ca_bundle:
        raise RuntimeError('Build machine needs ca-certificates to include trusted roots')
    copy_file(Path(ca_bundle), engine / 'share/cacert.pem')
    linux_launcher(engine / 'bin/remina-rdp', binary, library_dir / loader.name, library_dir)
    # Some GLib/GTK libraries are supplied by plugins, not the runner executable.
    runner = root / 'remina'
    real_runner = root / 'remina.bin'
    if is_elf(runner):
        runner.replace(real_runner)
    if not real_runner.is_file():
        raise RuntimeError('Flutter Linux runner is missing')
    app_libraries = root / 'lib'
    seeds = [real_runner, *[p for p in app_libraries.glob('*') if is_elf(p)]]
    for seed in seeds:
        for dependency in elf_dependencies(seed):
            copy_file(dependency, app_libraries / dependency.name)
    # EGL is loaded with dlopen by Flutter; Mesa in turn loads its driver.
    cache = run(['ldconfig', '-p'])
    extra_files = []
    for name in ['libGL.so.1', 'libGLX.so.0', 'libEGL.so.1', 'libGLESv2.so.2', 'libEGL_mesa.so.0', 'libGLX_mesa.so.0', 'libgbm.so.1']:
        match = re.search(r'\s' + re.escape(name) + r'\s+.*?=>\s+(\S+)', cache)
        if not match:
            raise RuntimeError(f'Build machine is missing {name}; cannot package the graphics runtime')
        extra = Path(match[1])
        extra_files.append(extra)
        for dependency in [extra, *elf_dependencies(extra)]:
            copy_file(dependency, app_libraries / dependency.name)
    driver_candidates = list(Path('/usr/lib').glob('*/dri/swrast_dri.so'))
    if not driver_candidates:
        raise RuntimeError('Mesa software driver swrast_dri.so is required on the build machine')
    driver = driver_candidates[0]
    for mesa_driver in driver.parent.glob('*_dri.so'):
        copy_file(mesa_driver, app_libraries / 'dri' / mesa_driver.name)
    extra_files.append(driver)
    for dependency in elf_dependencies(driver):
        copy_file(dependency, app_libraries / dependency.name)
        extra_files.append(dependency)
    runtime = root / 'runtime'
    runtime.mkdir(exist_ok=True)
    copy_file(Path('/usr/share/glib-2.0/schemas/gschemas.compiled'), runtime / 'schemas/gschemas.compiled')
    (runtime / 'egl.json').write_text(json.dumps({'file_format_version': '1.0.0', 'ICD': {'library_path': 'libEGL_mesa.so.0'}}))
    fonts = list(Path('/usr/share/fonts/truetype/dejavu').glob('DejaVuSans*.ttf'))
    if not fonts:
        raise RuntimeError('Build requires fonts-dejavu-core to bundle fallback fonts')
    for font in fonts:
        copy_file(font, runtime / 'fonts' / font.name)
    (runtime / 'fonts.conf').write_text('<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd"><fontconfig><dir prefix="relative">fonts</dir><cachedir prefix="xdg">fontconfig</cachedir></fontconfig>')
    app_loader = elf_interpreter(real_runner)
    copy_file(app_loader, app_libraries / app_loader.name)
    linux_launcher(runner, real_runner, app_libraries / app_loader.name, app_libraries, graphics=True)
    if (root / 'licenses').exists():
        shutil.rmtree(root / 'licenses')
    licenses(root / 'licenses', [source, *dependencies, *extra_files, *fonts, *[p for seed in seeds for p in elf_dependencies(seed)]])
    manifest(engine, engine / 'manifest.json', 'linux', version)
    manifest(root, root / 'runtime-manifest.json', 'linux', version)
    # This runs the COPIED engine with its COPIED loader and libraries.
    run([engine / 'bin/remina-rdp', '/version'], env={'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent'})
    print(f'Bundled FreeRDP and {len(dependencies)} ELF dependencies: {engine}')


def macho_dependencies(binary):
    lines = run(['otool', '-L', binary]).splitlines()[1:]
    return [line.strip().split(' (compatibility version')[0] for line in lines if line.startswith('\t')]


def macho_rpaths(binary):
    output = run(['otool', '-l', binary])
    return re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', output)


def system_dylib(name):
    return name.startswith(('/System/Library/', '/usr/lib/'))


def resolve_macho(name, binary, executable, rpaths):
    def expand(path):
        return Path(path.replace('@loader_path', str(binary.parent)).replace('@executable_path', str(executable.parent)))
    if name.startswith('@rpath/'):
        tail = name[len('@rpath/'):]
        for prefix in [*macho_rpaths(binary), *rpaths]:
            path = expand(prefix) / tail
            if path.is_file():
                return path.resolve()
    else:
        path = expand(name)
        if path.is_file():
            return path.resolve()
    raise RuntimeError(f'Cannot resolve {name} from {binary}')


def macos_bundle(root, source, sign):
    version = run([source, '/version'])
    if not re.search(r'\b3\.\d+', version):
        raise RuntimeError('Only FreeRDP 3 is supported')
    # Standard Apple code locations; never put Mach-O code in Resources.
    executable = root / 'Contents/MacOS/remina-rdp'
    main_binary = root / 'Contents/MacOS/Remina'
    if main_binary.is_file():
        required_arches = set(run(['lipo', '-archs', main_binary]).split())
        engine_arches = set(run(['lipo', '-archs', source]).split())
        if not required_arches.issubset(engine_arches):
            raise RuntimeError(f'Engine architectures {engine_arches} do not cover application {required_arches}')
    library_dir = root / 'Contents/Frameworks/ReminaRdp'
    if library_dir.exists():
        shutil.rmtree(library_dir)
    if executable.exists():
        executable.unlink()
    copy_file(source, executable)
    mapping = {source.resolve(): executable}
    queue = [source.resolve()]
    root_rpaths = macho_rpaths(source)
    edges = []
    while queue:
        original = queue.pop(0)
        copied = mapping[original]
        for name in macho_dependencies(original):
            if system_dylib(name):
                continue
            resolved = resolve_macho(name, original, source, root_rpaths)
            if resolved == original:  # dylib's own LC_ID_DYLIB
                continue
            if '.framework/' in str(resolved):
                raise RuntimeError('Non-system frameworks require a source build using dylibs: ' + str(resolved))
            if resolved not in mapping:
                target = library_dir / resolved.name
                copy_file(resolved, target)
                mapping[resolved] = target
                queue.append(resolved)
            edges.append((copied, name, mapping[resolved]))
            if resolved.name.startswith('libcrypto'):
                for provider in (resolved.parent / 'ossl-modules').glob('*.dylib'):
                    provider = provider.resolve()
                    if provider not in mapping:
                        target = library_dir / 'ossl-modules' / provider.name
                        copy_file(provider, target)
                        mapping[provider] = target
                        queue.append(provider)
    # Remove existing signatures before rewriting paths.
    for copied in mapping.values():
        subprocess.run(['codesign', '--remove-signature', str(copied)], capture_output=True)
    for copied, old, dependency in edges:
        replacement = '@loader_path/' + os.path.relpath(dependency, copied.parent)
        run(['install_name_tool', '-change', old, replacement, copied])
    for original, copied in mapping.items():
        for rpath in macho_rpaths(original):
            if rpath.startswith(('/opt/', '/usr/local/', '/Users/', '/private/')):
                run(['install_name_tool', '-delete_rpath', rpath, copied])
        if copied != executable:
            run(['install_name_tool', '-id', '@loader_path/' + copied.name, copied])
    for copied in mapping.values():
        for name in macho_dependencies(copied):
            if not system_dylib(name) and not name.startswith('@loader_path/'):
                raise RuntimeError(f'Non-relocatable dependency remains: {copied}: {name}')
        run(['codesign', '--force', '--sign', sign, copied])
    # Advertise the actual minimum OS required by the copied code instead of
    # claiming the app will run on an older system than its RDP libraries.
    info_path = root / 'Contents/Info.plist'
    if info_path.is_file():
        info = plistlib.loads(info_path.read_bytes())
        minimums = [info.get('LSMinimumSystemVersion', '12.0')]
        for original in mapping:
            load_commands = run(['otool', '-l', original])
            minimums += re.findall(r'\bminos (\d+\.\d+(?:\.\d+)?)', load_commands)
            minimums += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+\.\d+(?:\.\d+)?)', load_commands)
        info['LSMinimumSystemVersion'] = max(minimums, key=lambda value: tuple(int(part) for part in value.split('.')))
        info_path.write_bytes(plistlib.dumps(info))
    candidates = [ssl.get_default_verify_paths().cafile,
        '/opt/homebrew/etc/ca-certificates/cert.pem', '/usr/local/etc/ca-certificates/cert.pem', '/etc/ssl/cert.pem']
    ca_bundle = next((Path(p) for p in candidates if p and Path(p).is_file()), None)
    if ca_bundle is None:
        raise RuntimeError('Missing CA roots on the build machine')
    certificate = root / 'Contents/Resources/rdp-cacert.pem'
    if certificate.exists():
        certificate.unlink()
    copy_file(ca_bundle, certificate)
    licenses(root / 'Contents/Resources/ThirdPartyLicenses')
    manifest(library_dir, root / 'Contents/Resources/rdp-manifest.json', 'macos', version)
    run([executable, '/version'], env={'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent'})
    print(f'Bundled FreeRDP and {len(mapping)-1} dylibs: {executable}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['linux', 'macos'], required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--source', default=os.environ.get('REMINA_FREERDP_SOURCE'))
    parser.add_argument('--sign', default=os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-')
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir():
        raise RuntimeError(f'Application bundle does not exist: {root}')
    source = available_source(args.source, args.platform)
    if args.platform == 'linux':
        linux_bundle(root, source)
    else:
        macos_bundle(root, source, args.sign)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError) as error:
        print(f'Packaging failed: {error}', file=sys.stderr)
        sys.exit(1)
