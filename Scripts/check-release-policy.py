#!/usr/bin/env python3
"""Fail closed before public binary upload; never inspect user wallet data."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = {'application', 'swift-dependencies', 'go-dependencies', 'go-runtime', 'tor', 'monero', 'node', 'privacy-helper'}


def local_file(root, name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or not name:
        raise ValueError('Materials paths must be project relative')
    target = root/name
    if target.is_symlink() or not target.is_file() or not target.resolve().is_relative_to(root.resolve()):
        raise ValueError('Missing or unsafe release materials')
    return target


def validate(policy, root=ROOT, source_tree=None):
    if policy.get('version') != 1 or type(policy.get('enabled')) is not bool:
        raise ValueError('Invalid binary distribution policy')
    if not policy['enabled']:
        return False
    build_info = json.loads(local_file(root, 'build/BUILD-INFO.json').read_text())
    if not source_tree or build_info.get('sourceTree') != source_tree or build_info.get('dirty') is not False:
        raise ValueError('Binary was not built from the exact clean release tree')
    manifest = json.loads(local_file(root, policy.get('materialsManifest') or '').read_text())
    if manifest.get('version') != 1 or not source_tree or manifest.get('sourceTree') != source_tree:
        raise ValueError('Materials do not match the exact release source tree')
    if manifest.get('reviewedForBinaryDistribution') is not True or manifest.get('relinkVerified') is not True:
        raise ValueError('Corresponding-source/relink review is incomplete')
    if set(manifest.get('components', [])) != COMPONENTS:
        raise ValueError('Corresponding-source component inventory is incomplete')
    # Every source/relink delivery is inventoried as an actual local artifact.
    artifacts = manifest.get('artifacts', [])
    if not artifacts:
        raise ValueError('No corresponding-source/relink artifacts supplied')
    for item in artifacts:
        path = local_file(root, item['path'])
        if hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
            raise ValueError('Release material hash mismatch')
    return True


def stage_materials(policy, root=ROOT, source_tree=None):
    if not validate(policy, root, source_tree):
        return
    manifest = json.loads(local_file(root, policy['materialsManifest']).read_text())
    target = root/'build/release-materials'
    if target.is_symlink():
        raise ValueError('Unsafe release material output')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.release-materials-', dir=target.parent) as directory:
        staged = Path(directory); names = {'MANIFEST.json'}; delivered = []
        for item in manifest['artifacts']:
            source = local_file(root, item['path']); name = source.name
            if name in names:
                raise ValueError('Colliding release material filenames')
            names.add(name); shutil.copyfile(source, staged/name)
            if hashlib.sha256((staged/name).read_bytes()).hexdigest() != item['sha256']:
                raise ValueError('Release material changed during staging')
            delivered.append(dict(path=name, sha256=item['sha256']))
        manifest['artifacts'] = delivered
        (staged/'MANIFEST.json').write_text(json.dumps(manifest, indent=2)+'\n')
        if target.exists(): shutil.rmtree(target)
        shutil.copytree(staged, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-binary', action='store_true')
    parser.add_argument('--github-output', type=Path)
    parser.add_argument('--stage-materials', action='store_true')
    parser.add_argument('--configuration-only', action='store_true', help='Validate policy shape without a binary build; never enables upload')
    args = parser.parse_args()
    if args.configuration_only and (args.require_binary or args.stage_materials or args.github_output):
        parser.error('Configuration-only checks cannot authorize binary upload')
    try:
        policy = json.loads((ROOT/'Configuration/BinaryDistribution.json').read_text())
        if args.configuration_only:
            if policy.get('version') != 1 or type(policy.get('enabled')) is not bool:
                raise ValueError('Invalid binary distribution policy')
            if policy['enabled']:
                name = policy.get('materialsManifest') or ''
                path = PurePosixPath(name)
                if not name or path.is_absolute() or '..' in path.parts:
                    raise ValueError('Missing or unsafe materials manifest path')
            print('Policy configuration checked; exact-tree materials validation is still required before upload')
            return 0
        tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=ROOT).decode().strip()
        enabled = validate(policy, source_tree=tree)
        if enabled and args.stage_materials:
            stage_materials(policy, source_tree=tree)
        if args.github_output:
            with args.github_output.open('a') as stream:
                stream.write('enabled=' + str(enabled).lower() + '\n')
        print('Binary distribution: enabled with reviewed materials' if enabled else 'Binary distribution: disabled; source-preview builds remain available locally')
        return int(args.require_binary and not enabled)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print('Binary distribution blocked: invalid policy or unverified source/relink materials')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
