#!/usr/bin/env python3
"""Verify a Linux distribution is intact and resolves its own native libraries.

--container IMAGE additionally starts the included engine in a network-isolated
container with no FreeRDP install, mounting the app at a different path.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def command(args):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def verify(root):
    root = root.resolve()
    data = json.loads((root / 'runtime-manifest.json').read_text())
    for record in data['files']:
        path = (root / record['path']).resolve()
        if not path.is_relative_to(root):
            raise RuntimeError('Manifest path escapes the application')
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != record['sha256']:
            raise RuntimeError(f'Missing or altered bundled file: {record["path"]}')
    for base, binary in [(root, root / 'remina.bin'), (root / 'rdp', root / 'rdp/bin/freerdp')]:
        loaders = list((base / 'lib').glob('ld-linux*.so*'))
        if len(loaders) != 1:
            raise RuntimeError(f'Expected one bundled loader in {base}')
        output = command([loaders[0], '--inhibit-cache', '--library-path', base / 'lib', '--list', binary])
        if 'not found' in output:
            raise RuntimeError(output)
        for line in output.splitlines():
            match = re.search(r'=>\s+(/.*?)\s+\(', line)
            if match and not Path(match[1]).resolve().is_relative_to(base):
                raise RuntimeError(f'Host library used instead of bundled library: {line}')
    version = command([root / 'rdp/bin/remina-rdp', '/version'])
    print(f'PASS: {len(data["files"])} packaged files verified; app and engine use bundled libraries. {version.strip()}')


def container_check(root, image):
    result = command(['docker', 'run', '--rm', '--network', 'none',
        '-v', f'{root.resolve()}:/relocated Remina:ro', image, 'sh', '-c',
        'if command -v xfreerdp || command -v xfreerdp3 || command -v sdl-freerdp; then exit 1; fi; '
        'exec "/relocated Remina/rdp/bin/remina-rdp" /version'])
    print(f'PASS: relocated engine starts in {image}, no FreeRDP installed and no network. {result.strip()}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--container')
    args = parser.parse_args()
    try:
        verify(args.bundle)
        if args.container:
            container_check(args.bundle, args.container)
    except (OSError, RuntimeError, ValueError) as error:
        print(f'Bundle verification failed: {error}', file=sys.stderr)
        sys.exit(1)
