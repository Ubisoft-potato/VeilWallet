#!/usr/bin/env python3
"""Developer-only: pin public provider identifiers; never run in the app.

Input: .build/price-reference/chains.json from https://api.llama.fi/v2/chains.
Use gasTokenGeckoId, not governance token gecko_id (e.g. OP/ARB != ETH).
"""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
upstream = json.loads((root / '.build/price-reference/chains.json').read_text())
by_id = {str(row.get('chainId')): row for row in upstream if row.get('chainId') is not None}
by_name = {row['name'].lower(): row for row in upstream}
aliases = {14: 'flare', 1116: 'core', 1030: 'conflux', 10001: 'ethereumpow', 999: 'hyperliquid l1', 2222: 'kava', 4200: 'merlin', 1329: 'sei', 369: 'pulsechain', 196: 'x layer', 50: 'xdc'}
# Provider chain identifiers are distinct from UI names. No symbol lookup for tokens.
namespaces = {1:'ethereum',10:'optimism',14:'flare',25:'cronos',30:'rsk',50:'xdc',56:'bsc',130:'unichain',137:'polygon',143:'monad',146:'sonic',196:'xlayer',324:'era',480:'wc',988:'stable',999:'hyperliquid',1030:'conflux',1329:'sei',2222:'kava',2818:'morph',4217:'tempo',4326:'megaeth',5000:'mantle',8453:'base',9745:'plasma',42161:'arbitrum',42220:'celo',43114:'avax',57073:'ink',59144:'linea',80094:'berachain',100:'xdai',250:'fantom',1284:'moonbeam',1285:'moonriver',534352:'scroll',81457:'blast',1101:'polygon_zkevm'}
# Restrict identifiers to the safe path alphabet accepted by MarketPriceClient.
# Polygon zkEVM's upstream namespace contains '_'; leave unsupported until pinned.
namespaces.pop(1101)
rows = []
for chain in json.loads((root / 'Sources/WalletCore/Resources/evm-networks.json').read_text()):
    ident = chain['id']
    reference = by_id.get(str(ident)) or by_name.get(aliases.get(ident, '')) or {}
    gecko = reference.get('gasTokenGeckoId')
    # Unverified gas-asset identity and USD-designated networks stay unpriced.
    if ident in [2818, 5042, 4217]: gecko = None
    row = dict(chainID=ident, family='evm', nativeSymbol=chain['symbol'], nativeDecimals=chain.get('decimalsHint',18))
    if gecko: row['nativePriceID'] = 'coingecko:' + gecko
    if ident in namespaces: row['tokenNamespace'] = namespaces[ident]
    rows.append(row)

native = [
 (128,'monero','XMR',12,'monero'), (0,'bitcoin','BTC',8,'bitcoin'), (2,'litecoin','LTC',8,'litecoin'),
 (501,'solana','SOL',9,'solana'), (195,'tron','TRX',6,'tron'), (784,'sui','SUI',9,'sui'),
 (637,'aptos','APT',8,'aptos'), (607,'ton','TON',9,'the-open-network'), (397,'near','NEAR',24,'near'),
 (5757,'stacks','STX',6,'blockstack'), (1815,'cardano','ADA',6,'cardano'), (9004,'starknet','STRK',18,'starknet'),
 (14001,'eos','WAXP',8,'wax'), (354,'polkadot','DOT',10,'polkadot'),
]
cosmos = [('ATOM','cosmos',6),('OSMO','osmosis',6),('TIA','celestia',6),('INJ','injective-protocol',18),('SEI','sei-network',6),('JUNO','juno-network',6),('AKT','akash-network',6),('SCRT','secret',6),('KUJI','kujira',6),('STARS','stargaze',6),('STRD','stride',6),('NTRN','neutron-3',6),('DYDX','dydx-chain',18),('USDC','usd-coin',6),('XPRT','persistence',6),('AXL','axelar',6),('BAND','band-protocol',6),('IRIS','iris-network',6),('KAVA','kava',6),('LUNA','terra-luna-2',6),('LUNC','terra-luna',6),('HUAHUA','chihuahua-token',6),('DVPN','sentinel',6),('CMDX','comdex',6)]
native += [(100000+i,'cosmos',symbol,decimals,gecko) for i,(symbol,gecko,decimals) in enumerate(cosmos)]
for index,family,symbol,decimals,gecko in native:
    row = dict(chainID=(1<<63)|index, family=family, nativeSymbol=symbol, nativeDecimals=decimals, nativePriceID='coingecko:'+gecko)
    if family == 'tron': row['tokenNamespace']='tron'
    rows.append(row)
sources = ['https://api.llama.fi/v2/chains','https://api-docs.defillama.com/llms-free.txt','https://coins.llama.fi/prices/current/{chain}:{contract}','https://www.coingecko.com/en/coins/{coin-id}']
catalog = dict(version=1, verifiedDate='2026-11-04', sources=sources, networks=sorted(rows,key=lambda x:x['chainID']))
(root/'Sources/WalletCore/Resources/market-prices.json').write_text(json.dumps(catalog,indent=2,ensure_ascii=False)+'\n')
print('Pinned market identities for',len(rows),'networks')
