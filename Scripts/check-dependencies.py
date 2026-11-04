#!/usr/bin/env python3
"""Check the actual offline runtime graph against OSV; reports contain public package metadata only."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def source_policy(root=ROOT):
    policy = json.loads((root/'Configuration/PrivacyDependencyPolicy.json').read_text())['snarkjs']
    guards = policy.get('sourceGuards', {})
    required = {'Tools/PrivacyProof/main.cjs', 'Tools/PrivacyProof/snarkjs-prover-entry.cjs',
                'Sources/WalletCore/Networking/PrivacyPoolClient.swift'}
    if set(guards) != required:
        raise ValueError('Missing proof-boundary source review')
    for name, expected in guards.items():
        if hashlib.sha256((root/name).read_bytes()).hexdigest() != expected:
            raise ValueError('Proof boundary changed; review its advisory disposition')
    return policy


def runtime_policy(policy, root=ROOT):
    runtime = root/'Vendor/PrivacyRuntime'
    expected = (root/policy['entry']).read_bytes()
    packages = list((runtime/'node_modules').rglob('snarkjs/package.json'))
    if not packages:
        raise ValueError('Missing collected snarkjs runtime')
    for package in packages:
        folder = package.parent
        if json.loads(package.read_text())['version'] != policy['version'] or (folder/'index.js').read_bytes() != expected:
            raise ValueError('Unreviewed snarkjs runtime entry')
        for file in folder.rglob('*'):
            if file.is_file() and any(file.relative_to(folder).as_posix().startswith(p) for p in policy['excludedSourcePrefixes']):
                raise ValueError('Excluded verification/setup code was packaged')
    graph = json.loads((runtime/'LOAD_GRAPH.json').read_text())
    if any('/snarkjs/src/verifier' in '/' + name or '/snarkjs/src/setup' in '/' + name or '/snarkjs/src/prover' in '/' + name for name in graph):
        raise ValueError('Excluded code entered the loaded dependency graph')
    return True


def reviewed_advisory(query, advisory, proof_checked):
    return (proof_checked and query['package'] == {'name': 'snarkjs', 'ecosystem': 'npm'}
            and query['version'] == '0.1.20' and advisory == 'GHSA-xp5g-jhg3-3rg2')


def queries(root=ROOT):
    lines = subprocess.check_output([str(root/'Scripts/go.sh'), 'list', '-mod=readonly', '-tags=gofuzz,purego',
        '-deps', '-f', '{{with .Module}}{{.Path}}|{{.Version}}{{end}}', '.'], cwd=root/'Native/ChainCore').decode().splitlines()
    unique = set()
    for line in lines:
        if '|' not in line: continue
        name, version = line.split('|', 1)
        if not version or name.startswith('github.com/okx/') and version == 'v0.0.0': continue
        unique.add(('Go', name, version))
    toolchain = json.loads((root/'Configuration/Toolchains.json').read_text())['go']
    unique.add(('Go', 'stdlib', toolchain.removeprefix('go')))
    for package in json.loads((root/'Vendor/PrivacyRuntime/DEPENDENCIES.json').read_text()):
        unique.add(('npm', package['name'], package['version']))
    return [dict(package=dict(ecosystem=ecosystem, name=name), version=version) for ecosystem, name, version in sorted(unique)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--policy-only', action='store_true')
    parser.add_argument('--offline-runtime', action='store_true')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        policy = source_policy()
        if args.policy_only:
            print('Dependency source-policy passed; online/runtime advisory checks were not requested')
            return 0
        proof_checked = runtime_policy(policy)
        if args.offline_runtime:
            print('Collected prover-only runtime verified; advisory database was not refreshed')
            return 0
        batch = queries()
        request = urllib.request.Request('https://api.osv.dev/v1/querybatch',
            data=json.dumps({'queries': batch}).encode(), headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=45) as response:
            results = json.load(response)['results']
        if len(results) != len(batch): raise ValueError('Incomplete advisory response')
        reviewed, unresolved = [], []
        for query, result in zip(batch, results):
            if result.get('error'): raise ValueError('Advisory query failed')
            for advisory in result.get('vulns', []):
                finding = dict(package=query['package'], version=query['version'], advisory=advisory['id'])
                (reviewed if reviewed_advisory(query, advisory['id'], proof_checked) else unresolved).append(finding)
        report = dict(version=1, scope='Compiled Go modules/toolchain and collected proof-runtime package versions',
            source='https://api.osv.dev/v1/querybatch', queries=len(batch), reviewed=reviewed, unresolved=unresolved,
            disposition='The sole reviewed advisory has affected verification code physically excluded and hash-bound source checks; unknown advisories fail closed.')
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2)+'\n')
        for finding in unresolved:
            print('REVIEW dependency: ' + finding['package']['name'] + ' ' + finding['version'] + ' ' + finding['advisory'])
        print(f'Dependency check: {len(batch)} version queries, {len(reviewed)} reviewed, {len(unresolved)} unresolved')
        return bool(unresolved)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print('Dependency check failed closed; prepare verified runtimes, inspect the policy and restore advisory-service access')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
