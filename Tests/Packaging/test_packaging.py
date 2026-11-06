"""Distribution and cleanup safety checks; all payloads are synthetic."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'Scripts' / file)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


verify = module('verify_app', 'verify-app.py')
clean = module('clean_build_cache', 'clean-build-cache.py')


class PackagingTests(unittest.TestCase):
    def fake_app(self, directory):
        app = Path(directory) / 'Fixture.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources').mkdir()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='app.veilwallet.macos', CFBundlePackageType='APPL', CFBundleExecutable='Fixture')))
        (app / 'Contents/MacOS/Fixture').write_bytes(b'synthetic executable')
        return app

    def test_public_resources_are_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.fake_app(directory)
            (app / 'Contents/Resources/ca.pem').write_text('-----BEGIN CERTIFICATE-----')
            self.assertEqual(verify.inspect(app)[1], [])

    def test_wallet_files_cannot_ship(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.fake_app(directory)
            (app / 'Contents/Resources/vault.json').write_text('{}')
            self.assertTrue(any(rule == 'wallet / credential / log filename' for _, rule in verify.inspect(app)[1]))

    def test_private_key_and_build_path_cannot_ship(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.fake_app(directory)
            (app / 'Contents/Resources/example.txt').write_text('-----BEGIN ' + 'RSA PRIVATE KEY-----')
            (app / 'Contents/MacOS/Fixture').write_bytes(str(Path.home()).encode() + b'/synthetic')
            rules = {rule for _, rule in verify.inspect(app)[1]}
            self.assertIn('private key block', rules)
            self.assertIn('local build path', rules)

    def test_cleanup_refuses_tracked_source(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(clean, 'ROOT', Path(directory)):
            with self.assertRaises(ValueError): clean.validate_target('.build', ['.build/keep.swift'])
            self.assertEqual(clean.validate_target('.build', ['Sources/main.swift']), Path(directory) / '.build')

    def test_cleanup_never_follows_external_symlink(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            base = Path(directory)
            canary = Path(outside) / 'keep'; canary.write_text('public canary')
            (base / '.build').symlink_to(outside, target_is_directory=True)
            with patch.object(clean, 'ROOT', base):
                clean.remove(clean.validate_target('.build', []))
                self.assertTrue(canary.exists())
                for name in ['../outside', '..', '.', '/tmp']:
                    with self.subTest(name=name), self.assertRaises(ValueError): clean.validate_target(name, [])

    def test_workflow_only_publishes_verified_tagged_artifacts(self):
        workflow = (ROOT / '.github/workflows/macos-dmg.yml').read_text()
        triggers = workflow.split('\non:\n', 1)[1].split('\n\n', 1)[0]
        self.assertEqual(triggers, "  push:\n    tags: ['v*']")
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('contents: read', workflow)
        self.assertIn('cache: false', workflow)
        self.assertNotIn('secrets.', workflow)
        self.assertNotIn('pull_request_target', workflow)
        build, release = workflow.split('  release:', 1)
        self.assertIn('if: github.event.created', build)
        self.assertNotIn('contents: write', build)
        self.assertIn("startsWith(github.ref, 'refs/tags/v')", release)
        self.assertIn("needs.build.outputs.distribution == 'true'", release)
        self.assertIn('contents: write', release)
        self.assertLess(release.index('sha256sum -c SHA256SUMS'), release.index('gh release create'))
        self.assertLess(release.index('gh release download'), release.index('gh release edit'))
        self.assertIn('--draft --prerelease', release)
        upload = workflow.split('path: |', 1)[1].split('if-no-files-found:', 1)[0]
        self.assertNotIn('.build', upload)
        self.assertNotIn('.tools', upload)
        self.assertNotIn('**', upload)

    def test_cleanup_removes_readonly_module_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / '.build'
            nested = cache / 'module' / 'sub'; nested.mkdir(parents=True)
            file = nested / 'fixture.txt'; file.write_text('public fixture'); file.chmod(0o444)
            nested.chmod(0o555); nested.parent.chmod(0o555)
            with patch.object(clean, 'ROOT', Path(directory)):
                clean.remove(clean.validate_target('.build', []))
            self.assertFalse(cache.exists())


if __name__ == '__main__':
    unittest.main()
