# Public EVM endpoints through Tor

Historical validation: 2026-11-02. Wallet TorTransport and bundled Tor checked 56 prioritized mainnets plus ETHW genesis. Each run verified Tor/Sepolia before probing and blocked requests after stopping Tor. These are read-only results, not funded-transfer acceptance or current availability promises.

Of the 56 prioritized networks, 49 passed balance/fee/gas/adapted-extra-fee checks, six were partial and one unavailable. Manta/Metis/Morph/Hemi lack complete extra-fee adapters. Abstract/zkSync returned balance/gasPrice but the public burn-address zero-value estimate reverted with RPC code 3. Flare returned 403; alternate TLS/connection failures were not bypassed. See [raw results](evm-rpc-report.json).

No user vault was opened, no signatures/broadcasts occurred, and no balances, addresses or exit IPs were logged. ERC20 and fee-budget coverage also uses mocks/independent vectors. Endpoints below are historical; later default migrations are described in [EVM.md](EVM.md) and [DEX.md](DEX.md).

| Network | Chain ID | Balance | Fee quote | Gas estimate | Result / fee model | Endpoint at validation |
|---|---:|---|---|---|---|---|
| Ethereum | 1 | ✓ | ✓ | ✓ | Passed · standard | https://ethereum-rpc.publicnode.com |
| Optimism | 10 | ✓ | ✓ | ✓ | Passed · opStack | https://optimism-rpc.publicnode.com |
| Flare | 14 | — | — | — | Unavailable · standard | https://flare-api.flare.network/ext/C/rpc |
| Cronos | 25 | ✓ | ✓ | ✓ | Passed · standard | https://evm.cronos.org |
| Rootstock | 30 | ✓ | ✓ | ✓ | Passed · standard | https://public-node.rsk.co |
| Telos | 40 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.telos.net |
| XDC | 50 | ✓ | ✓ | ✓ | Passed · standard | https://xdc.public-rpc.com/ |
| BNB Chain | 56 | ✓ | ✓ | ✓ | Passed · standard | https://bsc-rpc.publicnode.com |
| Gnosis | 100 | ✓ | ✓ | ✓ | Passed · standard | https://gnosis-rpc.publicnode.com |
| Unichain | 130 | ✓ | ✓ | ✓ | Passed · opStack | https://mainnet.unichain.org |
| Polygon | 137 | ✓ | ✓ | ✓ | Passed · standard | https://polygon-bor-rpc.publicnode.com |
| Monad | 143 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.monad.xyz |
| Sonic | 146 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.soniclabs.com |
| Manta Pacific | 169 | ✓ | ✓ | ✓ | Partial · executionOnly | https://pacific-rpc.manta.network/http |
| X Layer | 196 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.xlayer.tech |
| opBNB | 204 | ✓ | ✓ | ✓ | Passed · opStack | https://opbnb-mainnet-rpc.bnbchain.org |
| Fantom | 250 | ✓ | ✓ | ✓ | Passed · standard | https://fantom.drpc.org |
| Fraxtal | 252 | ✓ | ✓ | ✓ | Passed · opStack | https://rpc.frax.com |
| Filecoin EVM | 314 | ✓ | ✓ | ✓ | Passed · standard | https://api.node.glif.io/rpc/v1 |
| zkSync Era | 324 | ✓ | ✓ | — | Partial · standard | https://zksync.drpc.org |
| PulseChain | 369 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.pulsechain.com |
| World Chain | 480 | ✓ | ✓ | ✓ | Passed · opStack | https://worldchain-mainnet.g.alchemy.com/public |
| Astar | 592 | ✓ | ✓ | ✓ | Passed · standard | https://astar.api.onfinality.io/public |
| HyperEVM | 999 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.hyperliquid.xyz/evm |
| Metis | 1088 | ✓ | ✓ | ✓ | Partial · executionOnly | https://andromeda.metis.io/?owner=1088 |
| Lisk | 1135 | ✓ | ✓ | ✓ | Passed · opStack | https://lisk.drpc.org |
| Moonbeam | 1284 | ✓ | ✓ | ✓ | Passed · standard | https://moonbeam.api.onfinality.io/public |
| Moonriver | 1285 | ✓ | ✓ | ✓ | Passed · standard | https://moonriver.api.onfinality.io/public |
| Sei EVM | 1329 | ✓ | ✓ | ✓ | Passed · standard | https://evm-rpc.sei-apis.com |
| Soneium | 1868 | ✓ | ✓ | ✓ | Passed · opStack | https://rpc.soneium.org |
| Ronin | 2020 | ✓ | ✓ | ✓ | Passed · standard | https://api.roninchain.com/rpc |
| Abstract | 2741 | ✓ | ✓ | — | Partial · standard | https://abstract.drpc.org |
| Morph | 2818 | ✓ | ✓ | ✓ | Partial · executionOnly | https://rpc.morphl2.io |
| IoTeX | 4689 | ✓ | ✓ | ✓ | Passed · standard | https://babel-api.mainnet.iotex.io |
| Mantle | 5000 | ✓ | ✓ | ✓ | Passed · mantle | https://rpc.mantle.xyz |
| ZetaChain | 7000 | ✓ | ✓ | ✓ | Passed · standard | https://zetachain-evm.blockpi.network/v1/rpc/public |
| Kaia | 8217 | ✓ | ✓ | ✓ | Passed · standard | https://public-en.node.kaia.io |
| Base | 8453 | ✓ | ✓ | ✓ | Passed · opStack | https://base-rpc.publicnode.com |
| Plasma | 9745 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.plasma.to |
| Immutable zkEVM | 13371 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.immutable.com |
| ApeChain | 33139 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.apechain.com |
| Arbitrum One | 42161 | ✓ | ✓ | ✓ | Passed · standard | https://arbitrum-one-rpc.publicnode.com |
| Arbitrum Nova | 42170 | ✓ | ✓ | ✓ | Passed · standard | https://nova.arbitrum.io/rpc |
| Celo | 42220 | ✓ | ✓ | ✓ | Passed · standard | https://celo-rpc.publicnode.com |
| Hemi | 43111 | ✓ | ✓ | ✓ | Partial · executionOnly | https://rpc.hemi.network/rpc |
| Avalanche C | 43114 | ✓ | ✓ | ✓ | Passed · standard | https://avalanche-c-chain-rpc.publicnode.com |
| Zircuit | 48900 | ✓ | ✓ | ✓ | Passed · opStack | https://mainnet.zircuit.com |
| Ink | 57073 | ✓ | ✓ | ✓ | Passed · opStack | https://ink-rpc.publicnode.com |
| Linea | 59144 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.linea.build |
| Berachain | 80094 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.berachain.com |
| Blast | 81457 | ✓ | ✓ | ✓ | Passed · opStack | https://rpc.blast.io |
| Scroll | 534352 | ✓ | ✓ | ✓ | Passed · scroll | https://rpc.scroll.io |
| Katana | 747474 | ✓ | ✓ | ✓ | Passed · standard | https://rpc.katana.network |
| Zora | 7777777 | ✓ | ✓ | ✓ | Passed · opStack | https://rpc.zora.energy/ |
| Aurora | 1313161554 | ✓ | ✓ | ✓ | Passed · standard | https://mainnet.aurora.dev |
| Harmony | 1666600000 | ✓ | ✓ | ✓ | Passed · standard | https://api.harmony.one |
| EthereumPoW (additional check) | 10001 | ✓ | ✓ | ✓ | Passed · standard | https://mainnet.ethereumpow.org |


Other catalog mainnets were not checked in this run. Historical networks, authenticated providers and other Tor exits require separate validation. No contract execution or funded receipt acceptance is implied.
