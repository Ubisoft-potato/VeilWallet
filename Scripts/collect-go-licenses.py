#!/usr/bin/env python3
"""Collect notices for the Go packages actually compiled into ChainCore, including local SDK modules."""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
out = root / 'Configuration/Licenses/ChainCore'
env = dict(os.environ, GOCACHE=str(root / '.build/go-cache'), GOMODCACHE=str(root / '.build/go-mod'))
lines = subprocess.check_output(['go', 'list', '-mod=readonly', '-tags=gofuzz', '-deps', '-f', '{{with .Module}}{{.Path}}|{{.Version}}|{{.Dir}}{{end}}', '.'], cwd=root / 'Native/ChainCore', env=env, text=True)
out.mkdir(parents=True, exist_ok=True)
modules = sorted(set(line for line in lines.splitlines() if line and not line.startswith('app.veilwallet.chaincore|')))
manifest = []
def copy_notice(source, destination):
    if destination.exists():
        destination.chmod(0o644)
    shutil.copyfile(source, destination)
    destination.chmod(0o644)

for line in modules:
    name, version, directory = line.split('|', 2)
    source = Path(directory)
    target = out / name / (version or 'vendored')
    notices = []
    for file in source.rglob('*'):
        if file.is_file() and file.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
            rel = file.relative_to(source)
            dest = target / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            copy_notice(file, dest)
            notices.append(str(rel))
    # Each SDK module inherits the root MIT notice, even when its own module has none.
    if name.startswith('github.com/okx/go-wallet-sdk'):
        target.mkdir(parents=True, exist_ok=True)
        copy_notice(root / 'Vendor/OKXWalletSDK/LICENSE', target / 'SDK-LICENSE')
        notices.append('SDK-LICENSE')
        blocks = {}
        for file in source.rglob('*.go'):
            if file.name.endswith('_test.go'):
                continue
            for comment in re.findall(r'/\*[\s\S]*?\*/|(?://[^\n]*(?:\n|$))+', file.read_text(errors='replace')):
                if re.search(r'copyright|licensed under|permission is hereby granted', comment, re.I):
                    blocks.setdefault(comment.strip(), []).append(str(file.relative_to(source)))
        if blocks:
            (target / 'SOURCE-NOTICES.txt').write_text('\n\n'.join('\n'.join(files) + '\n' + block for block, files in blocks.items()) + '\n')
            notices.append('SOURCE-NOTICES.txt')
    if name == 'github.com/dchest/blake2b' and not notices:
        # This upstream dedicates its source to CC0 in the file header, without a LICENSE file.
        header = (source / 'blake2b.go').read_text().split('// Package blake2b', 1)[0]
        target.mkdir(parents=True, exist_ok=True)
        (target / 'SOURCE-LICENSE').write_text(header)
        notices.append('SOURCE-LICENSE')
    manifest.append({'module': name, 'version': version or 'vendored at ' + (root / 'Vendor/OKXWalletSDK/UPSTREAM_COMMIT').read_text().strip(), 'notices': notices})
    if not notices:
        raise RuntimeError('Missing upstream license for ' + name)
goroot = Path(subprocess.check_output(['go', 'env', 'GOROOT'], text=True).strip())
license_file = next((p for p in [goroot / 'LICENSE', goroot.parent / 'LICENSE'] if p.is_file()), None)
if license_file is None:
    raise RuntimeError('Go runtime LICENSE not found')
(out / 'Go').mkdir(exist_ok=True)
copy_notice(license_file, out / 'Go/LICENSE')
(out / 'Go/VERSION').write_text(subprocess.check_output(['go', 'version'], text=True))
(out / 'modules.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Collected license notices for', len(modules), 'compiled modules and Go runtime')
