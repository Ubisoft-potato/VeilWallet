"""Portable documentation paths, using synthetic local fixtures only."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('docs_check', ROOT/'Scripts/check-documentation.py')
docs = importlib.util.module_from_spec(spec); spec.loader.exec_module(docs)


class DocumentationTests(unittest.TestCase):
    def test_absolute_paths_and_root_links_are_rejected(self):
        for text in ['`/Users' + '/example/project`', '`~/Library/example`', '[file](/tmp/file)', 'file:///tmp/file', r'C:\Users\example\file']:
            self.assertTrue(docs.inspect_text('README.md', text))

    def test_urls_and_portable_shell_variables_are_allowed(self):
        for text in ['https://example.com/' + 'home/public', '"$PWD/.build/report.json"', 'Sources/WalletCore/', '[API](https://example.com/a)']:
            self.assertEqual(docs.inspect_text('README.md', text), [])

    def test_relative_links_exist_and_do_not_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'README.md').write_text('fixture')
            self.assertEqual(docs.inspect_text('Doc.md', '[read](README.md)', root), [])
            self.assertTrue(docs.inspect_text('Doc.md', '[read](missing.md)', root))
            self.assertTrue(docs.inspect_text('Doc.md', '[read](../outside.md)', root))

    def test_primary_documentation_is_english_and_upstream_is_classified(self):
        self.assertTrue(docs.inspect_text('README.md', '中文'))
        self.assertTrue(docs.owned('Documentation/SECURITY.md'))
        self.assertFalse(docs.owned('Vendor/SDK/README.md'))
        self.assertFalse(docs.owned('Configuration/Licenses/SDK/LICENSE.txt'))


if __name__ == '__main__': unittest.main()
