#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Create/verify the offline runtime inventory, also after nested code signing."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('--verify', action='store_true')
args = parser.parse_args()
base = args.directory
resources = base if (base / 'node').exists() else base / 'Contents/Resources'
node = base / 'node' if (base / 'node').exists() else base / 'Contents/MacOS/node'
target = resources / 'manifest.json' if resources == base else base.parent.parent / 'Resources/PrivacyRuntime-manifest.json'
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
files = {}
for path in sorted(resources.rglob('*')):
    assert not path.is_symlink(), f'Symlink in privacy runtime: {path.name}'
    if path.is_file() and path != node and path != target:
        files[path.relative_to(resources).as_posix()] = digest(path)
assert 5 <= len(files) <= 3000
manifest = dict(version=1, nodeVersion='24.22.2', nodeSHA256=digest(node), files=files)
if args.verify:
    assert json.loads(target.read_text()) == manifest, 'Offline privacy runtime inventory mismatch'
    print(f'Privacy runtime verified: {len(files)} resources')
else:
    target.write_text(json.dumps(manifest, indent=2) + '\n')
