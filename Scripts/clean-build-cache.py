#!/usr/bin/env python3
"""Remove only known, untracked project build caches. Never access wallet data."""
import argparse
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CACHES = ['.build', '.index-build', '.swiftpm', 'Tools/PrivacyProof/node_modules', 'Scripts/__pycache__', 'Tests/SourceAudit/__pycache__', 'Tests/Packaging/__pycache__']
DOWNLOADS = ['Vendor/Tor', 'Vendor/Monero', 'Vendor/PrivacyRuntime/node', 'Vendor/PrivacyRuntime/node_modules',
             'Vendor/PrivacyRuntime/artifacts', 'Vendor/PrivacyRuntime/manifest.json', 'Vendor/PrivacyRuntime/DEPENDENCIES.json',
             'Vendor/PrivacyRuntime/main.cjs', 'Vendor/PrivacyRuntime/package-lock.json', 'Vendor/PrivacyRuntime/NODE-LICENSE',
             'Vendor/PrivacyRuntime/source/build']


def validate_target(relative, tracked):
    path = PurePosixPath(relative)
    if not relative or relative == '.' or path.is_absolute() or '..' in path.parts:
        raise ValueError('Refusing a non-relative cache path')
    target = ROOT / relative
    # Resolve only the parent: a target symlink is removed, never traversed.
    if not target.parent.resolve().is_relative_to(ROOT.resolve()) or target == ROOT:
        raise ValueError('Refusing a path outside the project')
    if any(p == relative or p.startswith(relative + '/') for p in tracked):
        raise ValueError('Refusing to remove tracked source files')
    return target


def size(target):
    if target.is_symlink(): return 0
    if target.is_file(): return target.stat().st_size
    total = 0
    for base, _, files in os.walk(target, followlinks=False):
        for name in files:
            path = Path(base) / name
            if not path.is_symlink(): total += path.stat().st_size
    return total


def remove(target):
    if target.is_symlink() or target.is_file(): target.unlink()
    elif target.is_dir():
        # Go modules are normally stored in read-only directories. Make only
        # directories inside this validated disposable target removable.
        for base, _, _ in os.walk(target, topdown=True, followlinks=False):
            if not Path(base).is_symlink():
                os.chmod(base, stat.S_IMODE(os.stat(base).st_mode) | 0o700, follow_symlinks=False)
        shutil.rmtree(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Delete; otherwise print a dry run')
    parser.add_argument('--downloads', action='store_true', help='Also remove verified runtime downloads and installed dependencies')
    args = parser.parse_args()
    tracked = subprocess.check_output(['git','ls-files','-z'], cwd=ROOT).decode().split('\0')
    names = list(CACHES)
    if args.downloads:
        names += DOWNLOADS
        names += [p.relative_to(ROOT).as_posix() for p in (ROOT/'Vendor').glob('tor-expert-bundle-*.tar.gz*') if p.is_file()]
    targets = [validate_target(name, tracked) for name in names]
    total = 0
    for target in targets:
        if not target.exists() and not target.is_symlink(): continue
        count = size(target); total += count
        print(f"{'REMOVE' if args.apply else 'WOULD REMOVE'} {target.relative_to(ROOT)} ({count / 1024**2:.1f} MiB)")
        if args.apply: remove(target)
    print(f"{'Removed' if args.apply else 'Selected'} logical bytes: {total} ({total / 1024**3:.2f} GiB)")
    print('Preserved: Git, source, packaged outputs, public verification keys and .tools audit utilities.')


if __name__ == '__main__':
    main()
