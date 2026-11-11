# Product scope and network matrix

Version 0.10.1 uses native i18n configuration with immediate English/Simplified Chinese switching, retaining current inputs and session state. Version 0.10.0 added English documentation and portable path checks. Earlier releases added prices, asset discovery, transaction management, bridges/privacy pools and DEX continuation. No cross-Mac recovery or cloud sync is provided.

The fixed development catalog contains 123 entries: 81 EVM mainnets, Sepolia and BSC testnets, 39 non-EVM networks and Nostr. There are 51 derivable account profiles plus arbitrary-script LTC watch entry. Catalog coverage, implemented protocol paths, endpoint availability and funded acceptance are separate. See [protocol execution acceptance](PROTOCOL_ACCEPTANCE.md) for the specific local-chain and public-testnet results; production-funds acceptance is not claimed.

| Family | Import | Balance | Sending |
|---|---|---|---|
| EVM | BIP32/BIP44; 32-byte hex; EIP55 | Chain ID/native/ERC20 | EIP-1559/Legacy native/ERC20; Tempo/Arc disabled |
| Bitcoin | BIP44/49/84/86; WIF; Legacy/Nested/Native/Taproot | Esplora + genesis | Selected-address confirmed single-key UTXOs |
| Litecoin | L/M/old 3/ltc1q/ltc1p; WIF; MWEB key pair; arbitrary-script watch | Esplora + genesis; MWEB unknown | Five transparent single-key profiles; scripts/MWEB disabled |
| Monero | Ledger-style BIP39; English native 25-word seed/spend key | Official local scan | Local signed preview and separate relay; funded acceptance outstanding |
| Solana | Three/four-level SLIP10; Base58/JSON/32/64-byte | Genesis + balance | SOL only |
| TRON | BIP44; secp256k1 hex | Genesis/native/TRC20 | Single-key TRX and adapted DEX/bridge/approvals; no multisig |
| Sui | Ed25519 SLIP10; suiprivkey/hex | GraphQL identity/totalBalance | Unavailable |
| Aptos | Ed25519 SLIP10; AIP80/hex | REST chain_id/coin balance | APT ordinary Ed25519, authentication/sequence/BCS checks |
| TON | BIP39/SLIP10; seed/keypair; V4R2/V5R1 | TON Center | Unavailable |
| Cosmos, 24 entries | Coin-specific path/HRP; Injective Ethereum-style key hash | Bank denomination; 19 endpoints need configuration | 21 Bank adapters with ID/sequence/simulation/memo; exclusions below |
| NEAR | SLIP10 implicit account; ed25519:Base58/hex/JSON | view_account | Unavailable |
| Stacks | BIP44 compressed secp256k1 | Hiro available STX | Unavailable |
| Cardano | CIP-1852; 128-byte payment/stake extended private keys | Koios address_info | Unavailable |
| Polkadot | Ed25519 BIP44 only; 32/64-byte, not sr25519/SURI | Known runtime/System.Account layouts | Unavailable |
| EOS/WAX | K1/WIF/PVT_K1; bind permission key to account | Requires binding | Unavailable |
| Starknet | Stark private key; BIP32/StarkWare grind; account binding | Mainnet ID/STRK balance | Unavailable |
| Nostr | NIP06/nsec/npub | Identity only; no relay | Unavailable |

EVM operations verify chain ID and reject unknown/failed responses. Unsupported L2 additional fees are disclosed; catalog presence is not complete fee/funding acceptance. See [EVM](EVM.md).

Cosmos has five preset REST endpoints; other entries need configuration. Sending requires simulation and node gas price or an explicit user price. Stargaze/Comdex are marked stopped upstream; Terra Classic transfer tax is unadapted; these three are disabled. IDs/provenance are in [COSMOS_SOURCES.json](COSMOS_SOURCES.json). Chain-specific ante rules/endpoints still require acceptance.

EOS permission keys and Starknet public keys are not receive accounts/contracts. Manual binding does not prove control. Rotated Aptos accounts, native TON mnemonics, named NEAR recovery and Polkadot sr25519 are outside scope. Import previews must match existing addresses. LTC arbitrary scripts cannot be inferred from one key; MWEB scanning/sending is unavailable. See [Litecoin](LITECOIN.md) and [Monero](MONERO.md).

## Product capabilities

| Area | Implemented | Not implemented/accepted |
|---|---|---|
| Custody | Create/import/watch, multiple wallets, backup/rename/remove/password change, migrations | Hardware/xpub/offline signing, more keystore/seed formats |
| Assets | Configured native/token discovery, addresses, USD prices/totals, stale/partial labels, local icons/QR, searchable chains | Arbitrary unknown-token/NFT/history indexing, all price coverage, SPL/generic non-EVM tokens |
| Transfers | EVM/BTC/LTC/SOL/TRX/APT/Cosmos/XMR, encrypted archives, supported state/rebroadcast/replacement tools | Remaining protocols, generic non-EVM tokens, full L2 fees, contract-account replacement, funded acceptance |
| Contracts/DEX | Bounded typed ABI, simulation, 82 EVM deployments and two TRON modes, exact/Permit2 approvals/continuation | Arbitrary hooks, 1inch/0x, taxed tokens, LP/limit orders/MEV protection |
| Bridges/privacy | Fixed USDT ETH↔TRON/ETH↔BSC, dual-chain GUID verification, Classic ETH/BNB notes/offline proofs/direct withdrawal | TRON mixer, RAILGUN/relayers, automated multi-leg routes, more assets, funded end-to-end acceptance |
| DApp/NFT/DeFi | Clearly labeled planned screens | WalletConnect/permissions/EIP712/origin binding, positions/media/indexing |
| Privacy/macOS | Bundled Tor/remote DNS/fail-closed, local encryption, configurable lock, English/Chinese, native keyboard/click/render checks | Full system capture, independent audit, Intel hardware acceptance, Developer ID/notarization/reproducible build |

Only implemented adapters expose write actions. New protocols require real read/write encoding, test-network end-to-end/error recovery and the same Tor boundary. No embedded OKX API key, WalletConnect project ID, analytics or automatic RPC provider probing. The app is independent and does not claim OKX equivalence. Product research: [wallet management](https://www.okx.com/en-us/help/how-do-i-manage-my-wallet-web), [DApp network scope](https://web3.okx.com/onchainos/dev-docs/wallet/dapp-connect/okx-wallet-integration-supported-networks), [OnchainOS](https://web3.okx.com/onchainos/dev-docs/wallet/supported-networks); these product scopes are not interchangeable.

## EVM mainnet catalog

Exact configuration is in [evm-networks.json](../Sources/WalletCore/Resources/evm-networks.json). Registries were read at development time; runtime does not fetch them. Historical entries/custom-node import do not guarantee surviving services.

| Name | Chain ID | Native symbol |
|---|---:|---|
| Ethereum | 1 | ETH |
| 0G | 16661 | 0G |
| Abstract | 2741 | ETH |
| ApeChain | 33139 | APE |
| Arbitrum Nova | 42170 | ETH |
| Arbitrum One | 42161 | ETH |
| Arc | 5042 | USDC |
| Astar | 592 | ASTR |
| Aurora | 1313161554 | ETH |
| Avalanche C | 43114 | AVAX |
| Base | 8453 | ETH |
| Berachain | 80094 | BERA |
| BitLayer | 200901 | BTC |
| BitTorrent Chain | 199 | BTT |
| Blast | 81457 | ETH |
| BNB Chain | 56 | BNB |
| BOB | 60808 | ETH |
| Boba | 288 | ETH |
| Celo | 42220 | CELO |
| Chiliz | 88888 | CHZ |
| Conflux eSpace | 1030 | CFX |
| Core | 1116 | CORE |
| Cronos | 25 | CRO |
| Endurance | 648 | ACE |
| EthereumPoW | 10001 | ETHW |
| Fantom | 250 | FTM |
| Filecoin EVM | 314 | FIL |
| Flare | 14 | FLR |
| Fraxtal | 252 | FRAX |
| Gnosis | 100 | XDAI |
| Gravity Alpha | 1625 | G |
| Haqq Network | 11235 | ISLM |
| Harmony | 1666600000 | ONE |
| HECO | 128 | HT |
| Hemi | 43111 | ETH |
| HyperEVM | 999 | HYPE |
| Immutable zkEVM | 13371 | IMX |
| Ink | 57073 | ETH |
| IoTeX | 4689 | IOTX |
| Kaia | 8217 | KAIA |
| Katana | 747474 | ETH |
| Kava EVM | 2222 | KAVA |
| Linea | 59144 | ETH |
| Lisk | 1135 | ETH |
| Manta Pacific | 169 | ETH |
| Mantle | 5000 | MNT |
| MegaETH | 4326 | ETH |
| Merlin | 4200 | BTC |
| Metis | 1088 | METIS |
| Mode | 34443 | ETH |
| Monad | 143 | MON |
| Moonbeam | 1284 | GLMR |
| Moonriver | 1285 | MOVR |
| Morph | 2818 | ETH |
| OKT Chain | 66 | OKT |
| opBNB | 204 | BNB |
| Optimism | 10 | ETH |
| Plasma | 9745 | XPL |
| Polygon | 137 | POL |
| Polygon zkEVM | 1101 | ETH |
| PulseChain | 369 | PLS |
| Robinhood | 4663 | ETH |
| Ronin | 2020 | RON |
| Rootstock | 30 | RBTC |
| Scroll | 534352 | ETH |
| Sei EVM | 1329 | SEI |
| Soneium | 1868 | ETH |
| Sonic | 146 | S |
| Stable | 988 | USDT0 |
| Taiko | 167000 | ETH |
| Telos | 40 | TLOS |
| Tempo | 4217 | USD |
| Unichain | 130 | ETH |
| World Chain | 480 | ETH |
| X Layer | 196 | OKB |
| XDC | 50 | XDC |
| ZetaChain | 7000 | ZETA |
| Zircuit | 48900 | ETH |
| zkFair | 42766 | USDC |
| zkSync Era | 324 | ETH |
| Zora | 7777777 | ETH |
