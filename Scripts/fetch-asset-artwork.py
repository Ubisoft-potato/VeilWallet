#!/usr/bin/env python3
"""Build-time only: pinned public PNG logos; no runtime downloads or wallet data."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REF = ROOT / '.build/asset-reference'
DEST = ROOT / 'Sources/WalletCore/Resources/AssetLogos'
DEST.mkdir(parents=True, exist_ok=True)
REPOS = json.loads((REF / 'repositories.json').read_text())
EXTRA = dict(akt='akash-network',astr='astar',axl='axelar',bera='berachain',celo='celo',cfx='conflux-network',core='core-dao',dvpn='sentinel',dydx='dydx',ethw='ethereum-pow',flr='flare',frax='frax',ftm='fantom',glmr='moonbeam',huahua='chihuahua',hype='hyperliquid',imx='immutable-x',inj='injective-protocol',iris='irisnet',islm='islamic-coin',juno='juno',kaia='kaia',kava='kava',kuji='kujira',luna='terra-luna',lunc='terra-luna',metis='metisdao',mon='monad',movr='moonriver',ntrn='neutron',okt='oec-token',pls='pulsechain',rbtc='rsk-smart-bitcoin',ron='ronin',scrt='secret',stars='stargaze',strd='stride',strk='starknet',tia='celestia',tlos='telos',waxp='wax',xdc='xinfin',xprt='persistence',zeta='zetachain')

def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'VeilWallet-build-artwork/0.8'})
    with urllib.request.urlopen(request, timeout=25) as response:
        data = response.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError('Artwork exceeds limit')
        return data

def download(item):
    key, path = item
    suffix = '/logo.png' if '/assets/' in path else '/info/logo.png'
    attempts = [f'https://raw.githubusercontent.com/trustwallet/assets/{REPOS["trustwallet/assets"]}/blockchains/{path}{suffix}'] if path else []
    if key == 'usdd':
        attempts.append(f'https://raw.githubusercontent.com/trustwallet/assets/{REPOS["trustwallet/assets"]}/blockchains/tron/assets/TPYmHEhy5n8TCEfYGqW2rPxsghSfzghPDn/logo.png')
    attempts.append(f'https://raw.githubusercontent.com/spothq/cryptocurrency-icons/{REPOS["spothq/cryptocurrency-icons"]}/128/color/{key}.png')
    if key in EXTRA:
        attempts.append(f'https://raw.githubusercontent.com/ErikThiart/cryptocurrency-icons/{REPOS["ErikThiart/cryptocurrency-icons"]}/128/{EXTRA[key]}.png')
    for url in attempts:
        try:
            data = fetch(url)
            if not data.startswith(b'\x89PNG\r\n\x1a\n'):
                continue
            target = DEST / ('asset-' + key + '.png'); target.write_bytes(data)
            return dict(key=key, source=url, sha256=hashlib.sha256(data).hexdigest())
        except (urllib.error.URLError, TimeoutError):
            continue
    return dict(key=key, fallback='Local letter badge; no remote image')

if __name__ == '__main__':
    if 'ErikThiart/cryptocurrency-icons' not in REPOS:
        REPOS['ErikThiart/cryptocurrency-icons'] = json.loads(fetch('https://api.github.com/repos/ErikThiart/cryptocurrency-icons/commits/master'))['sha']
        (REF / 'repositories.json').write_text(json.dumps(REPOS, indent=2)+'\n')
    mapping = dict(eth='ethereum',btc='bitcoin',ltc='litecoin',xmr='monero',sol='solana',trx='tron',sui='sui',apt='aptos',ton='ton',near='near',stx='stacks',ada='cardano',dot='polkadot',eos='eos',waxp='wax',atom='cosmos',osmo='osmosis',tia='celestia',inj='injective',sei='sei',bnb='smartchain',matic='polygon',pol='polygon',arbitrum='arbitrum',optimism='optimism',base='base',avax='avalanchec',zksync='zksync',linea='linea',scroll='scroll',mantle='mantle',mnt='mantle',gnosis='xdai',xdai='xdai',okb='xlayer',sonic='sonic',s='sonic',hype='hyperliquid',bera='berachain',dai='',usdt='',usdc='',usdd='',sun='',jst='')
    rows = json.loads((ROOT/'Sources/WalletCore/Resources/evm-networks.json').read_text())
    mapping.update(usdd='tron/assets/TXDk8mbtRbXeYuMNS83CfKPaYYT8XWv9Hz',sun='tron/assets/TSSMHYeV2uE9qYH95DqyoCuNCzEL1NvU3S',jst='tron/assets/TCFLL5dx5ZJdKnWuesXxi1VPwjLVmWZZy9',cro='cronos',cfx='conflux',inj='injective',okb='okxchain',wtrx='tron',usdt0='')
    for row in rows:
        mapping.setdefault(row['symbol'].lower(), '')
    for key in ['akt','scrt','kuji','stars','strd','ntrn','dydx','xprt','axl','band','iris','kava','luna','lunc','huahua','dvpn','cmdx','juno','strk','wtrx','btt','kaia']:
        mapping.setdefault(key, '')
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        results = list(pool.map(download, sorted(mapping.items())))
    licenses = [('trustwallet/assets','LICENSE','TrustWallet-Assets-LICENSE.txt'),('spothq/cryptocurrency-icons','LICENSE.md','Cryptocurrency-Icons-CC0.txt'),('ErikThiart/cryptocurrency-icons','LICENSE','ErikThiart-Icons-LICENSE.txt')]
    for repo, original, filename in licenses:
        (ROOT/'Configuration'/filename).write_bytes(fetch(f'https://raw.githubusercontent.com/{repo}/{REPOS[repo]}/{original}'))
    report = dict(repositories=REPOS, runtimeDownloads=False, artwork=results)
    for row in results:
        if row['key'] == 'usdt0' and 'fallback' in row:
            row.pop('fallback'); row['alias'] = 'usdt'
    (ROOT/'Documentation/ASSET_ARTWORK.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Bundled PNG logos:',sum('sha256' in row for row in results))
    print('Local letter fallbacks:',','.join(row['key'] for row in results if 'fallback' in row))
