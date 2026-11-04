#!/usr/bin/env python3
"""Check distribution contents without launching the wallet or reading its data."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_NAMES = {'vault.json', 'local.sealed', 'wallet.dat', '.env', '.npmrc', '.netrc', '.git-credentials'}
FORBIDDEN_SUFFIXES = {'.sealed', '.keys', '.p12', '.pfx', '.keychain', '.keychain-db', '.log'}


def inspect(app):
    problems = []
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.veilwallet.macos' or info.get('CFBundlePackageType') != 'APPL':
        problems.append(('Contents/Info.plist', 'unexpected application identity'))
    main = app / 'Contents/MacOS' / info['CFBundleExecutable']
    # Upstream signed runtimes/artifacts can contain their upstream build paths.
    # Never rewrite those pinned inputs. Our executable must not contain the
    # current developer home; no packaged file may contain our checkout path.
    local_home = str(Path.home()).encode() + b'/'
    checkout = str(ROOT).encode() + b'/'
    pem = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')
    count = 0
    for path in app.rglob('*'):
        relative = path.relative_to(app).as_posix()
        if '.git' in path.parts or path.name.endswith('Tests.bundle'):
            problems.append((relative, 'development data'))
        if not path.is_file() or path.is_symlink():
            continue
        count += 1
        if path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
            problems.append((relative, 'wallet / credential / log filename'))
        data = path.read_bytes()
        if checkout in data or (path == main and local_home in data):
            problems.append((relative, 'local build path'))
        if path.suffix.lower() in {'.json', '.js', '.cjs', '.txt', '.md', '.pem', '.key'} and pem.search(data):
            problems.append((relative, 'private key block'))
    return count, problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        count, problems = inspect(args.app.resolve())
        for file, rule in problems:
            print(f'REJECT {file}: {rule}')
        if problems:
            return 1
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
        print(f'Packaged app check passed: {count} files, no local checkout or wallet-data files')
        return 0
    except (OSError, KeyError, ValueError, subprocess.SubprocessError):
        print('Packaged app validation failed')
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
