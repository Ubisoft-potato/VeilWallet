#!/usr/bin/env python3
"""Offline, redacting audit of the complete Git index or HEAD tree.

Gitleaks scans an isolated copy of exactly those blobs, not the working tree.
Wallet-specific checks also run over every text blob. Reviewed exceptions are
bound to a path, complete file SHA256 and rule; directories are never exempted.
This is a publication guard, not a proof that arbitrary source contains no secrets.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = 'Configuration/SourceAuditAllowlist.json'
VERSION = '8.30.1'
PATTERNS = {
    'private-key-block': re.compile(r'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|-----BEGIN PGP (?:PRIVATE) KEY BLOCK-----'),
    'personal-home': re.compile(r'/(?:Users|home)/[^/\s"\x27<>]+'),
    'credential-url': re.compile(r'https?://[^\s/"\x27]+:[^\s/"\x27]+@'),
    'credential-query': re.compile(r'(?i)[?&](?:api[_-]?key|token|access_token|secret|password)=[A-Za-z0-9_%+-]{8,}'),
    'secret-literal': re.compile(r'''(?i)(?:private[_-]?key|mnemonic|seed|password|passphrase|secret)\s*["']?\s*(?::\s*(?:String|string))?\s*[:=]\s*["'][^"'\n]{8,}'''),
    'encoded-private-key': re.compile(r'\b(?:xprv|tprv)[1-9A-HJ-NP-Za-km-z]{100,}\b|\b[KL][1-9A-HJ-NP-Za-km-z]{51}\b|\b(?:nsec1|suiprivkey1)[a-z0-9]{40,}\b|\bPVT_K1_[1-9A-HJ-NP-Za-km-z]{45,}\b'),
    'privacy-note': re.compile(r'tornado-[a-z]+-\d+(?:\.\d+)?-\d+-0x[0-9a-fA-F]{124}'),
    # Also catch unlabelled 32-byte keys. Public digests are reviewed explicitly.
    'hex-32-bytes': re.compile(r'(?<![a-zA-Z0-9])(?:0x)?[0-9a-fA-F]{64}(?![a-zA-Z0-9])'),
}
FORBIDDEN_PARTS = {'.git', '.build', '.index-build', '.swiftpm', '.tools', '.idea', '.vscode', 'node_modules', '__pycache__', 'xcuserdata', 'audit-private'}
FORBIDDEN_NAMES = {'vault.json', 'wallet.dat', 'local.sealed', 'id_rsa', 'id_ed25519', '.npmrc', '.netrc', '.pypirc', '.git-credentials'}
FORBIDDEN_SUFFIXES = {'.sealed', '.keychain', '.keychain-db', '.p12', '.pfx', '.mobileprovision', '.log', '.zip', '.gz', '.bz2', '.dmg', '.pyc', '.keys', '.note', '.notes'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(*args, data=None):
    return subprocess.check_output(['git', *args], cwd=ROOT, input=data, stderr=subprocess.DEVNULL)


def read_tree(source):
    records = git('ls-files', '--stage', '-z') if source == 'index' else git('ls-tree', '-r', '-z', 'HEAD')
    entries = []
    for record in records.split(b'\0'):
        if not record:
            continue
        meta, path = record.split(b'\t', 1)
        fields = meta.decode().split()
        if source == 'index':
            mode, oid, stage = fields
            if stage != '0':
                raise ValueError('Resolve all merge conflicts before auditing')
        else:
            mode, kind, oid = fields
            if kind != 'blob':
                raise ValueError('Submodules are not covered by this source audit')
        name = path.decode('utf-8')
        if not safe_path(name):
            raise ValueError('Unsafe path in Git tree')
        if mode not in ('100644', '100755'):
            raise ValueError('Symlinks and gitlinks are not allowed in the publication tree')
        entries.append((name, oid))
    if not entries:
        raise ValueError('Git tree is empty; stage the intended publication files first')
    output = git('cat-file', '--batch', data=''.join(oid + '\n' for _, oid in entries).encode())
    files, cursor = {}, 0
    for name, oid in entries:
        end = output.index(b'\n', cursor)
        header = output[cursor:end].split()
        if header[:2] != [oid.encode(), b'blob']:
            raise ValueError('Unexpected Git blob response')
        size = int(header[2]); cursor = end + 1
        files[name] = output[cursor:cursor + size]
        cursor += size + 1
    return files


def safe_path(name):
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and '..' not in path.parts and not any(ord(c) < 32 for c in name) and '\\' not in name


def forbidden_path(name):
    path = PurePosixPath(name)
    return (bool(set(path.parts) & FORBIDDEN_PARTS) or path.name in FORBIDDEN_NAMES
            or path.suffix.lower() in FORBIDDEN_SUFFIXES or path.name == '.env'
            or (path.name.startswith('.env.') and path.name != '.env.example')
            or name.startswith(('build/', 'Vendor/Tor/', 'Vendor/Monero/', 'Vendor/PrivacyRuntime/node_modules/', 'Vendor/PrivacyRuntime/artifacts/'))
            or name == 'Vendor/PrivacyRuntime/node' or any(p.endswith(('.app', '.dSYM')) for p in path.parts)
            or (name.startswith('Documentation/') and path.suffix.lower() in {'.png', '.jpg', '.jpeg', '.pdf'}))


def text_findings(name, data, words):
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return [('binary-review', 1)]
    if '\0' in text:
        return [('binary-review', 1)]
    found = []
    for rule, regex in PATTERNS.items():
        # Allowlist SHA256 fields are validated as hashes against actual blobs;
        # excluding just this rule here prevents a self-referential checksum.
        if name == ALLOWLIST and rule == 'hex-32-bytes':
            continue
        for match in regex.finditer(text):
            found.append((rule, text.count('\n', 0, match.start()) + 1))
    # Detect consecutive English BIP39 words, including line-wrapped phrases.
    # The actual 2048-word standard list is public data, verified by its review hash.
    run = []
    for match in re.finditer(r'[A-Za-z]+|[^A-Za-z\s]+', text):
        token = match.group()
        if token in words:
            run.append(match.start())
            if len(run) == 12:
                found.append(('mnemonic-words', text.count('\n', 0, run[0]) + 1))
        else:
            run = []
    return sorted(set(found))


def load_allowlist(files):
    if ALLOWLIST not in files:
        return {}
    raw = json.loads(files[ALLOWLIST])
    if raw.get('version') != 1 or not isinstance(raw.get('entries'), list):
        raise ValueError('Invalid source audit allowlist schema')
    allowed = {}
    for entry in raw['entries']:
        path, sha, rules, reason = (entry[k] for k in ('path', 'sha256', 'rules', 'reason'))
        if not safe_path(path) or path in allowed or path == ALLOWLIST or not re.fullmatch('[a-f0-9]{64}', sha):
            raise ValueError('Invalid or duplicate source audit allowlist entry')
        if not isinstance(reason, str) or len(reason) < 16 or not isinstance(rules, list) or not rules or not all(isinstance(r, str) for r in rules):
            raise ValueError('Every exception requires explicit rules and a review reason')
        allowed[path] = entry
    return allowed


def run_gitleaks(files, executable):
    env = {k: v for k, v in os.environ.items() if not k.startswith('GITLEAKS_')}
    version = subprocess.check_output([str(executable), 'version'], env=env, stderr=subprocess.DEVNULL).decode().strip()
    if version != VERSION:
        raise ValueError('Use the pinned Gitleaks version via Scripts/fetch-gitleaks.sh')
    with tempfile.TemporaryDirectory(prefix='veil-source-audit-') as directory:
        temp = Path(directory); snapshot = temp / 'tree'; snapshot.mkdir()
        copied = set()
        for name, data in files.items():
            # Do not let ignore files hide force-added blobs from the scanner.
            parts = [p + '.scantext' if p in {'.gitignore', '.gitleaksignore', '.gitleaks.toml'} else p for p in PurePosixPath(name).parts]
            target = snapshot.joinpath(*parts)
            if target in copied:
                raise ValueError('Conflicting scan snapshot paths')
            copied.add(target)
            target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        config = temp / 'defaults.toml'
        config.write_text('[extend]\nuseDefault = true\n')
        ignored = temp / 'empty.ignore'; ignored.write_text('')
        report = temp / 'redacted.json'
        result = subprocess.run([str(executable), 'dir', str(snapshot), '--config', str(config),
                                 '--gitleaks-ignore-path', str(ignored), '--ignore-gitleaks-allow',
                                 '--redact=100', '--no-banner', '--no-color', '--log-level', 'error',
                                 '--report-format', 'json', '--report-path', str(report)],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode not in (0, 1) or not report.exists():
            raise ValueError('Gitleaks failed; no scan result is accepted')
        findings = []
        for item in json.loads(report.read_bytes()):
            reported = Path(item['File'])
            name = reported.relative_to(snapshot).as_posix() if reported.is_absolute() else reported.as_posix()
            name = '/'.join(p.removesuffix('.scantext') if p in {'.gitignore.scantext', '.gitleaksignore.scantext', '.gitleaks.toml.scantext'} else p for p in name.split('/'))
            if name not in files:
                raise ValueError('Gitleaks reported an unexpected path')
            findings.append((name, 'gitleaks/' + item['RuleID'], item['StartLine']))
        return findings


def audit(files, executable):
    allowed = load_allowlist(files)
    words = set(files['Sources/WalletCore/Resources/bip39-english.txt'].decode().split())
    found = []
    for name, data in files.items():
        if forbidden_path(name):
            found.append((name, 'forbidden-path', 1))
        if len(data) > 5 * 1024 * 1024:
            found.append((name, 'large-file', 1))
        found.extend((name, rule, line) for rule, line in text_findings(name, data, words))
    found += run_gitleaks(files, executable)
    results = []
    for name, rule, line in sorted(set(found)):
        sha = digest(files[name]); entry = allowed.get(name, {})
        reviewed = (rule not in {'forbidden-path', 'large-file', 'private-key-block', 'personal-home'}
                    and entry.get('sha256') == sha and rule in entry.get('rules', []))
        results.append(dict(path=name, line=line, rule=rule, sha256=sha, reviewed=reviewed))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', choices=['index', 'head'], default='index')
    parser.add_argument('--gitleaks', type=Path, default=ROOT / '.tools/gitleaks/gitleaks')
    parser.add_argument('--report', type=Path, help='Write sanitized file/rule/hash metadata; no matched values')
    args = parser.parse_args()
    try:
        files = read_tree(args.source)
        results = audit(files, args.gitleaks.resolve())
        unresolved = [r for r in results if not r['reviewed']]
        report = dict(version=1, source=args.source, gitleaksVersion=VERSION, files=len(files), bytes=sum(map(len, files.values())),
                      reviewedFindings=len(results) - len(unresolved), unresolvedFindings=len(unresolved), findings=results)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + '\n')
        for item in unresolved:
            print(f"REVIEW {item['path']}:{item['line']} [{item['rule']}]")
        print(f"Source audit: {len(files)} files, {len(results) - len(unresolved)} reviewed public findings, {len(unresolved)} unresolved")
        return 1 if unresolved else 0
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        # Never echo exception strings or scanner output that might contain input.
        print('Source audit failed to run. Check the Git tree, allowlist schema and pinned scanner installation.')
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
