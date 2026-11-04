"""Public source staging rejects traversal, escaping links and private Git metadata."""
import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_materials', ROOT/'Scripts/release-materials.py')
materials = importlib.util.module_from_spec(spec); spec.loader.exec_module(materials)


class ReleaseMaterialsTests(unittest.TestCase):
    def test_archive_preserves_source_and_licenses_without_git_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root/'source'; source.mkdir()
            (source/'code.go').write_text('package publicfixture\n')
            (source/'LICENSE').write_text('public fixture license')
            (source/'.git').mkdir(); (source/'.git/config').write_text('excluded public canary')
            (source/'.build').mkdir(); (source/'.build/canary').write_text('excluded public canary')
            destination = root/'source.tar.gz'
            materials.archive(destination, [(source, 'dependency')])
            with tarfile.open(destination) as archive:
                names = set(archive.getnames())
                self.assertIn('dependency/code.go', names)
                self.assertIn('dependency/LICENSE', names)
                self.assertFalse(any('.git' in Path(n).parts or '.build' in Path(n).parts for n in names))
                self.assertTrue(all(m.uid == 0 and m.gid == 0 and not m.uname and not m.gname for m in archive))

    def test_escaping_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root/'source'; source.mkdir()
            (root/'outside').write_text('excluded public canary')
            (source/'link').symlink_to(root/'outside')
            with self.assertRaises(ValueError): materials.archive(root/'out.tar.gz', [(source, 'dependency')])

    def test_internal_symlink_is_delivered_as_source_contents(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root/'source'; source.mkdir()
            (source/'code').write_text('public fixture')
            (source/'alias').symlink_to('code')
            materials.archive(root/'out.tar.gz', [(source, 'dependency')])
            with tarfile.open(root/'out.tar.gz') as archive:
                self.assertEqual(archive.extractfile('dependency/alias').read(), b'public fixture')

    def test_archive_prefix_cannot_escape(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root/'source'; source.mkdir()
            for prefix in ['../outside', '/outside']:
                with self.assertRaises(ValueError): materials.archive(root/'out.tar.gz', [(source, prefix)])

    def test_source_inventory_contains_every_separate_runtime(self):
        config = materials.source_config()
        self.assertEqual({e['component'] for e in config['archives']}, {'tor', 'tor-build-recipes', 'lyrebird', 'node', 'monero'})


if __name__ == '__main__': unittest.main()
