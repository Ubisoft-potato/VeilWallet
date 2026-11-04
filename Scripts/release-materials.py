#!/usr/bin/env python3
"""Prepare explicit public-source deliveries and test LGPL library replacement.

Developer/CI only. Never opens a wallet, keychain or user data directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build'
COMPONENTS = ['application', 'swift-dependencies', 'go-dependencies', 'go-runtime', 'tor', 'monero', 'node', 'privacy-helper']


def run(args, **kwargs):
    return subprocess.check_output(args, cwd=ROOT, text=True, **kwargs).strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def identity():
    if run(['git', 'status', '--porcelain', '--untracked-files=all']):
        raise ValueError('Release materials require clean committed source')
    return run(['git', 'rev-parse', 'HEAD']), run(['git', 'rev-parse', 'HEAD^{tree}'])


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def source_config():
    config = json.loads((ROOT/'Configuration/ReleaseSources.json').read_text())
    if config.get('version') != 1 or not config.get('archives'):
        raise ValueError('Missing pinned upstream source inventory')
    for entry in config['archives']:
        if Path(entry['name']).name != entry['name'] or not entry['url'].startswith('https://'):
            raise ValueError('Unsafe upstream source location')
        if len(entry['sha256']) != 64 or any(c not in '0123456789abcdef' for c in entry['sha256']):
            raise ValueError('Invalid source hash')
    return config


def fetch():
    cache = ROOT/'.build/release-download'; cache.mkdir(parents=True, exist_ok=True)
    for entry in source_config()['archives']:
        target = cache/entry['name']
        if not target.is_file() or digest(target) != entry['sha256']:
            temporary = target.with_suffix(target.suffix + '.partial')
            subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3',
                            '--proto', '=https', '--tlsv1.2', entry['url'], '-o', str(temporary)], check=True)
            if digest(temporary) != entry['sha256']:
                temporary.unlink()
                raise ValueError('Upstream corresponding-source hash mismatch')
            temporary.replace(target)
        print('Verified upstream source:', entry['name'])


def archive(destination, entries):
    """Archive only enumerated public source roots; reject links escaping a root."""
    with tarfile.open(destination, 'w:gz', compresslevel=6, dereference=True) as output:
        for source, prefix in entries:
            if Path(prefix).is_absolute() or '..' in Path(prefix).parts:
                raise ValueError('Unsafe source archive prefix')
            source = source.resolve()
            if not source.exists():
                raise ValueError('Missing public source input')

            def check(info):
                parts = Path(info.name).parts
                if any(p in {'.git', '.build', '__pycache__', '.DS_Store'} for p in parts):
                    return None
                if info.isdev() or info.isfifo() or info.islnk():
                    raise ValueError('Unsupported source archive entry')
                relative = Path(info.name).relative_to(prefix)
                if not (source/relative).resolve().is_relative_to(source):
                    raise ValueError('Source symlink escapes its component')
                info.uid = info.gid = 0; info.uname = info.gname = ''
                return info

            output.add(source, arcname=prefix, filter=check)


def relink():
    commit, tree = identity()
    module_cache = ROOT/'.build/go-mod/github.com/ethereum/go-ethereum@v1.17.10/rlp'
    locations = [
        (ROOT/'Vendor/OKXWalletSDK/crypto/go-ethereum/crypto', 'crypto', 'VEIL_LGPL_VENDORED_RELINK_OK'),
        (module_cache, 'rlp', 'VEIL_LGPL_UPSTREAM_RELINK_OK'),
    ]
    patches = []; result = None; binary = None
    with tempfile.TemporaryDirectory(prefix='relink-', dir=ROOT/'.build') as temporary:
        temporary = Path(temporary)
        try:
            for directory, package, marker in locations:
                if not directory.is_dir():
                    raise ValueError('Build dependencies before testing library replacement')
                path = directory/'veil_release_relink_check.go'
                if path.exists():
                    raise ValueError('Refusing to overwrite an existing relink fixture')
                mode = directory.stat().st_mode & 0o777
                directory.chmod(mode | 0o700)
                patches.append((path, mode))
                path.write_text('// SPDX-License-Identifier: LGPL-3.0-or-later\npackage ' + package +
                                '\nfunc init() { println("' + marker + '") }\n')
            binary = Path(run(['./Scripts/swift.sh', 'build', '-c', 'release', '--show-bin-path']))/'VeilWallet'
            if not binary.resolve().is_relative_to(ROOT/'.build'):
                raise ValueError('Unexpected Swift product location')
            # A linked-library build setting is not always an incremental linker input.
            # Remove only this disposable product to force actual application relinking.
            binary.unlink(missing_ok=True)
            subprocess.run(['./Scripts/swift.sh', 'build', '-c', 'release'], cwd=ROOT, check=True)
            library = ROOT/'.build/ChainCore/libVeilChainCore.a'
            harness = temporary/'check.c'
            harness.write_text('#include <string.h>\n#include "CChainCore.h"\nint main(void) {\n'
                               'char *value = veil_chain_execute(0);\n'
                               'int ok = value && strstr(value, "Empty input");\n'
                               'veil_chain_free(value); return ok ? 0 : 1;\n}\n')
            executable = temporary/'check'
            subprocess.run(['clang', '-mmacosx-version-min=14.0', '-I', str(ROOT/'Sources/CChainCore/include'),
                            str(harness), str(library), '-framework', 'CoreFoundation', '-framework', 'Security',
                            '-lresolv', '-o', str(executable)], check=True)
            fixture = subprocess.run([str(executable)], capture_output=True, text=True, check=True)
            markers = [marker for _, _, marker in locations]
            if not all(marker in fixture.stderr and marker.encode() in binary.read_bytes() for marker in markers):
                raise ValueError('The replacement libraries were not executed')
            result = dict(version=1, sourceCommit=commit, sourceTree=tree, passed=True,
                          actualSwiftApplicationRelinked=True, modifiedApplicationSHA256=digest(binary),
                          modifiedStaticArchiveSHA256=digest(library), replacementSignals=markers,
                          fixture='C ABI empty-input validation; no wallet creation or network access',
                          patch='LGPL package init prints a public marker; no crypto primitive changed')
        finally:
            for path, mode in reversed(patches):
                path.unlink(missing_ok=True); path.parent.chmod(mode)
            if binary is not None: binary.unlink(missing_ok=True)
    if identity() != (commit, tree):
        raise ValueError('Source was not restored after replacement testing')
    result['sourcesRestored'] = True
    write_json(OUT/'RELINK-VERIFICATION.json', result)
    print('Verified modified LGPL libraries, C ABI and actual Swift application relink; restored sources.')


def prepare():
    commit, tree = identity()
    build = json.loads((OUT/'BUILD-INFO.json').read_text())
    proof = json.loads((OUT/'RELINK-VERIFICATION.json').read_text())
    if build.get('sourceTree') != tree or build.get('sourceCommit') != commit or build.get('dirty') is not False:
        raise ValueError('Package the exact committed application before preparing materials')
    if proof.get('sourceTree') != tree or proof.get('sourceCommit') != commit or not all(proof.get(k) is True for k in ['passed', 'sourcesRestored', 'actualSwiftApplicationRelinked']):
        raise ValueError('Missing exact-tree library replacement evidence')
    version = plistlib.loads((ROOT/'Configuration/Info.plist').read_bytes())['CFBundleShortVersionString']
    delivery = OUT/'corresponding-source'; delivery.mkdir(exist_ok=True)
    source = OUT/f'VeilWallet-{version}-source.tar.gz'
    subprocess.run(['git', 'archive', '--format=tar.gz', '--prefix=VeilWallet-source/', '-o', str(source), 'HEAD'], cwd=ROOT, check=True)
    entries = []
    for checkout in sorted((ROOT/'.build/checkouts').iterdir()):
        if checkout.is_dir(): entries.append((checkout, 'swift-dependencies/' + checkout.name))
    if len(entries) != 3:
        raise ValueError('Expected all three pinned Swift dependency source trees')
    env = dict(os.environ, GOCACHE=str(ROOT/'.build/go-cache'), GOMODCACHE=str(ROOT/'.build/go-mod'))
    modules = subprocess.check_output(
        [str(ROOT/'Scripts/go.sh'), 'list', '-mod=readonly', '-tags=gofuzz,purego', '-deps', '-f',
         '{{with .Module}}{{.Path}}|{{.Version}}|{{.Dir}}{{end}}', '.'], cwd=ROOT/'Native/ChainCore', env=env, text=True)
    inventory = []
    for module in sorted(set(modules.splitlines())):
        if not module or module.startswith('app.veilwallet.chaincore|'): continue
        name, revision, directory = module.split('|', 2)
        inventory.append(dict(module=name, version=revision or 'vendored; see application source'))
        if revision: entries.append((Path(directory), 'go-dependencies/' + name + '@' + revision))
    goroot = Path(run([str(ROOT/'Scripts/go.sh'), 'env', 'GOROOT']))
    for name in ['src', 'lib', 'doc', 'misc', 'test', 'LICENSE', 'PATENTS', 'VERSION', 'go.env', 'README.md', 'CONTRIBUTING.md']:
        if (goroot/name).exists(): entries.append((goroot/name, 'go-runtime/' + name))
    dependency_archive = delivery/f'VeilWallet-{version}-dependency-source.tar.gz'
    archive(dependency_archive, entries)
    privacy = ROOT/'build/Veil Wallet.app/Contents/Helpers/PrivacyRuntime.bundle/Contents/Resources'
    privacy_archive = delivery/f'VeilWallet-{version}-privacy-helper-source.tar.gz'
    archive(privacy_archive, [(privacy, 'privacy-helper')])
    upstream = []
    for item in source_config()['archives']:
        path = ROOT/'.build/release-download'/item['name']
        if not path.is_file() or digest(path) != item['sha256']:
            raise ValueError('Fetch and verify every pinned upstream source archive')
        upstream.append((path, 'upstream/' + item['name']))
    upstream.append((ROOT/'Configuration/ReleaseSources.json', 'upstream/SOURCES.json'))
    upstream_archive = delivery/f'VeilWallet-{version}-upstream-source.tar.gz'
    archive(upstream_archive, upstream)
    inventory_file = delivery/'SOURCE-INVENTORY.json'
    write_json(inventory_file, dict(version=1, sourceCommit=commit, sourceTree=tree, goModules=inventory,
               swiftPins=json.loads((ROOT/'Package.resolved').read_text()),
               runtimeSources=source_config(), licenses='Original notices retained in each source delivery and the application',
               instructions='VeilWallet-source/Documentation/RELINKING.md',
               distributionReview='Pinned source inventory, preserved component licenses, actual LGPL replacement/relink verification; no legal or security certification'))
    artifacts = [source, dependency_archive, privacy_archive, upstream_archive, inventory_file,
                 OUT/'RELINK-VERIFICATION.json', ROOT/'Documentation/RELINKING.md']
    manifest = dict(version=1, sourceTree=tree, sourceCommit=commit,
                    reviewedForBinaryDistribution=True, relinkVerified=True, components=COMPONENTS,
                    artifacts=[dict(path=p.relative_to(ROOT).as_posix(), sha256=digest(p)) for p in artifacts])
    write_json(OUT/'release-materials-manifest.json', manifest)
    print('Prepared exact-tree source deliveries and verified replacement/relink evidence.')


def upload():
    commit, tree = identity()
    build = json.loads((OUT/'BUILD-INFO.json').read_text())
    if build.get('sourceCommit') != commit or build.get('sourceTree') != tree or build.get('dirty') is not False:
        raise ValueError('Release upload requires the exact clean build')
    application = (OUT/'Veil Wallet.app/Contents/MacOS/VeilWallet').read_bytes()
    if b'VEIL_LGPL_VENDORED_RELINK_OK' in application or b'VEIL_LGPL_UPSTREAM_RELINK_OK' in application:
        raise ValueError('Temporary replacement-test code must not be distributed')
    subprocess.run(['python3', 'Scripts/check-release-policy.py', '--require-binary', '--stage-materials'], cwd=ROOT, check=True)
    folder = OUT/'release-upload'
    if folder.is_symlink(): raise ValueError('Unsafe upload staging path')
    if folder.exists(): shutil.rmtree(folder)
    folder.mkdir()
    version = build['version']
    files = [OUT/f'VeilWallet-{version}-macOS-arm64.dmg', OUT/'BUILD-INFO.json',
             OUT/'SOURCE-AUDIT.json', OUT/'HISTORY-AUDIT.json', OUT/'DEPENDENCY-CHECK.json']
    files += sorted((OUT/'release-materials').iterdir())
    files.append(ROOT/f'Documentation/RELEASE_NOTES/v{version}.md')
    for path in files:
        if path.is_symlink() or not path.is_file() or (folder/path.name).exists():
            raise ValueError('Missing, unsafe or colliding upload file')
        shutil.copyfile(path, folder/path.name)
    (folder/'SHA256SUMS').write_text(''.join(digest(p) + '  ' + p.name + '\n' for p in sorted(folder.iterdir())))
    (OUT/f'VeilWallet-{version}-macOS-arm64.zip').unlink(missing_ok=True)
    print('Staged only verified DMG, exact source deliveries and public verification reports.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['fetch', 'relink', 'prepare', 'upload'])
    args = parser.parse_args()
    OUT.mkdir(exist_ok=True)
    {'fetch': fetch, 'relink': relink, 'prepare': prepare, 'upload': upload}[args.command]()


if __name__ == '__main__': main()
