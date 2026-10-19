import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'bundle_runtime.py'
spec = importlib.util.spec_from_file_location('bundle_runtime', MODULE)
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class PackagingTests(unittest.TestCase):
    def test_unresolved_elf_dependency_prevents_distribution(self):
        with patch.object(bundle, 'run', return_value='libfreerdp3.so.3 => not found'):
            with self.assertRaisesRegex(RuntimeError, 'Unresolved'):
                bundle.elf_dependencies(Path('engine'))

    def test_macho_rpath_resolves_from_loader_location_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='Remina build ') as directory:
            root = Path(directory)
            engine = root / 'bin/client'
            engine.parent.mkdir()
            library = root / 'lib/libengine.dylib'
            library.parent.mkdir()
            library.write_bytes(b'fixture')
            with patch.object(bundle, 'macho_rpaths', return_value=['@loader_path/../lib']):
                self.assertEqual(bundle.resolve_macho('@rpath/libengine.dylib', engine, engine, []), library.resolve())
            with patch.object(bundle, 'macho_rpaths', return_value=[]):
                with self.assertRaisesRegex(RuntimeError, 'Cannot resolve'):
                    bundle.resolve_macho('@rpath/libmissing.dylib', engine, engine, [])

    def test_conflicting_library_names_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            first, other, target = [Path(directory) / name for name in ['one', 'two', 'target']]
            first.write_bytes(b'first ABI')
            other.write_bytes(b'other ABI')
            bundle.copy_file(first, target)
            with self.assertRaisesRegex(RuntimeError, 'Conflicting'):
                bundle.copy_file(other, target)

    def test_relocation_manifest_tracks_runtime_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'library').write_bytes(b'library fixture')
            bundle.manifest(root, root / 'manifest.json', 'linux', '3.fixture')
            import json
            manifest = json.loads((root / 'manifest.json').read_text())
            self.assertEqual(manifest['files'], [{'path': 'library', 'sha256': bundle.digest(root / 'library')}])

    def test_available_source_resolves_explicit_path(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = Path(directory) / 'sdl-freerdp'
            engine.write_bytes(b'fixture')
            self.assertEqual(bundle.available_source(str(engine), 'macos'), engine.resolve())


if __name__ == '__main__':
    unittest.main()
