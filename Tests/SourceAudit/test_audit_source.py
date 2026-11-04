"""Publication guard tests use synthetic text only, never a real credential."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('audit_source', ROOT / 'Scripts/audit-source.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
WORDLIST = 'Sources/WalletCore/Resources/bip39-english.txt'


class SourceAuditTests(unittest.TestCase):
    def findings(self, text):
        return {rule for rule, _ in audit.text_findings('fixture.txt', text.encode(), {'abandon', 'about'})}

    def test_mnemonic_across_lines(self):
        self.assertIn('mnemonic-words', self.findings(('abandon\n' * 11) + 'about'))

    def test_unlabelled_hex_key(self):
        self.assertIn('hex-32-bytes', self.findings('value = "' + '19' * 32 + '"'))

    def test_credentials_and_private_blocks(self):
        self.assertIn('credential-url', self.findings('https://' + 'test:synthetic-password@' + 'example.invalid'))
        self.assertIn('credential-query', self.findings('https://example.invalid/?token=' + 'synthetic-value'))
        self.assertIn('private-key-block', self.findings('-----BEGIN ' + 'OPENSSH PRIVATE KEY-----'))
        self.assertIn('private-key-block', self.findings('-----BEGIN PGP ' + 'PRIVATE KEY BLOCK-----'))

    def test_home_path_and_password(self):
        self.assertIn('personal-home', self.findings('/Users' + '/sample/project'))
        self.assertIn('secret-literal', self.findings('password = "' + 'synthetic-fixture-only' + '"'))

    def test_public_key_block_is_not_private(self):
        self.assertNotIn('private-key-block', self.findings('-----BEGIN PUBLIC KEY-----'))

    def test_forced_private_paths_are_rejected(self):
        for name in ['.env', 'sub/.env.production', '.idea/workspace.xml', 'build/release.zip', 'copies/vault.json',
                     'copies/private.sealed', 'Vendor/Monero/monero-wallet-rpc', 'node_modules/demo.js', '.npmrc', 'Documentation/account.png', '.tools/gitleaks/gitleaks']:
            with self.subTest(name=name):
                self.assertTrue(audit.forbidden_path(name))
        self.assertFalse(audit.forbidden_path('Vendor/monero-binaryfate.asc'))

    def test_binary_requires_review(self):
        self.assertEqual(audit.text_findings('image.png', b'\x89PNG\x00', set()), [('binary-review', 1)])

    def test_exception_requires_exact_file_hash(self):
        data = ('"' + '19' * 32 + '"').encode()
        files = {WORDLIST: b'about\n', 'fixture.txt': data}
        files[audit.ALLOWLIST] = json.dumps({'version': 1, 'entries': [dict(path='fixture.txt', sha256=audit.digest(data),
            rules=['hex-32-bytes'], reason='Synthetic public test material only')]}).encode()
        with patch.object(audit, 'run_gitleaks', return_value=[]):
            self.assertTrue(all(x['reviewed'] for x in audit.audit(files, None)))
            files['fixture.txt'] += b'\nchanged'
            self.assertTrue(any(not x['reviewed'] for x in audit.audit(files, None)))

    def test_ignored_wallet_file_cannot_be_allowlisted(self):
        files = {WORDLIST: b'about\n', 'vault.json': b'{}'}
        files[audit.ALLOWLIST] = json.dumps({'version': 1, 'entries': [dict(path='vault.json', sha256=audit.digest(b'{}'),
            rules=['forbidden-path'], reason='This exception must never take effect')]}).encode()
        with patch.object(audit, 'run_gitleaks', return_value=[]):
            self.assertTrue(any(not x['reviewed'] for x in audit.audit(files, None)))

    def test_index_reads_staged_blobs_not_worktree(self):
        with tempfile.TemporaryDirectory(prefix='veil-audit-test-') as directory:
            base = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            (base / 'fixture.txt').write_text('reviewed source')
            subprocess.run(['git', '-C', directory, 'add', 'fixture.txt'], check=True)
            (base / 'fixture.txt').write_text('different unstaged contents')
            with patch.object(audit, 'ROOT', base):
                self.assertEqual(audit.read_tree('index')['fixture.txt'], b'reviewed source')

    def test_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='veil-audit-test-') as directory:
            base = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            (base / 'link').symlink_to('/does-not-exist')
            subprocess.run(['git', '-C', directory, 'add', 'link'], check=True)
            with patch.object(audit, 'ROOT', base), self.assertRaises(ValueError):
                audit.read_tree('index')

    def test_gitleaks_scans_ignored_paths_and_returns_no_values(self):
        scanner = ROOT / '.tools/gitleaks/gitleaks'
        self.assertTrue(scanner.exists(), 'Run Scripts/fetch-gitleaks.sh first')
        synthetic = 'gh' + 'p_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'
        files = {'.gitignore': b'fixture.txt\n', '.gitleaksignore': b'fixture.txt:github-pat:1\n',
                 'fixture.txt': ('token = "' + synthetic + '"').encode()}
        results = audit.run_gitleaks(files, scanner)
        self.assertTrue(any(name == 'fixture.txt' and rule == 'gitleaks/github-pat' for name, rule, _ in results))
        self.assertNotIn(synthetic, repr(results))


if __name__ == '__main__':
    unittest.main()
