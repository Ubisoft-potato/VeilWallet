#!/usr/bin/env python3
"""Developer-only public reference fetch. Never shipped as a runtime request path."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.build/asset-reference'
CACHE.mkdir(parents=True, exist_ok=True)

def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'VeilWallet-build-reference/0.8'})
    with urllib.request.urlopen(request, timeout=40) as response:
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise ValueError('Reference too large')
        return data

if __name__ == '__main__':
    sources = {
        'circle.html': 'https://developers.circle.com/stablecoins/usdc-contract-addresses',
        'usdt0.json': 'https://docs.usdt0.to/api/deployments',
        'usdd.md': 'https://docs.usdd.io/developers/deployment-addresses.md',
        'sun-cli.md': 'https://raw.githubusercontent.com/sun-protocol/sun-cli/main/README.md',
    }
    for name, url in sources.items():
        data = fetch(url); (CACHE / name).write_bytes(data)
        print(name, hashlib.sha256(data).hexdigest())
    refs = {}
    for repo in ['trustwallet/assets', 'spothq/cryptocurrency-icons']:
        commit = json.loads(fetch(f'https://api.github.com/repos/{repo}/commits/master'))['sha']
        refs[repo] = commit
    (CACHE / 'repositories.json').write_text(json.dumps(refs, indent=2) + '\n')
    print('Pinned public artwork repositories.')
