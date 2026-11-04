# Validation record

Tests use public disposable vectors, mocks and isolated local infrastructure. No real user vault is opened and no funded mainnet transaction is signed/broadcast. A test pass, read-only RPC simulation, native preview or ad-hoc signature does not establish production safety.

## 0.10.1 — 2026-11-04

132 tests in 23 suites passed after 22.114 seconds. Nine language/documentation tool checks, seven packaging checks and twelve publication-guard checks passed. Both native language catalogs contain 1,638 matching stable keys. The source checker verifies argument counts and rejects translated Swift literals and direct interface text.

The new native check clicks the actual Settings language buttons in the same window, English to Simplified Chinese and back. Sidebar text and previously initialized account-profile labels update immediately; edited input, view identity, selected page and session state remain. The test uses an in-memory preference store/public preview model, without actual vault access, user-preference modification or network startup. See [I18N_0.10.1.json](I18N_0.10.1.json) and [i18n configuration](I18N.md).

The 0.10.0 previews below used separate processes and did not test an in-process language change. That validation gap is now covered. Native resource files replace sentence literals in Swift; legacy transaction labels remain fixed compatibility data.

## 0.10.0 — 2026-11-04

132 tests in 23 suites passed after 20.674 seconds for the English/Chinese implementation, including four localization tests. They verify bundled catalog loading/English values, placeholder parity and reordering, literal fallback, unchanged interpolated values, malformed-template rejection and canonical legacy transaction-state compatibility. Final layout and package checks are recorded in [LOCALIZATION_0.10.0.json](LOCALIZATION_0.10.0.json).

The default interface is English; the offline unlock screen and Settings offer Simplified Chinese. Language changes require restart and use non-sensitive local preferences. Vault schemas, stable identifiers, protocol bytes, amounts and legacy status decoding remain unchanged. App-generated historical descriptions are translated only for display when recognized.

All first-party Markdown is English. Documentation paths/relative links and English catalog coverage have automated checks; original third-party notices/provenance remain untouched. Historical report descriptions were translated without changing measured results.

## Recent historical validation

| Version | Automated result | Scope and evidence |
|---|---|---|
| 0.9.3 | 128 tests, 22 suites, 21.809s; 12 native click scenarios; seven hover rendering classes | [Clicks](UI_INTERACTION_0.9.3.json), [hover](UI_HOVER_0.9.3.json). Injected DEBUG phases drive the real handler; this does not validate OS pointer tracking. |
| 0.9.2 | 128 tests, 22 suites, 22.467s; 12 click scenarios | [Native clicks](UI_INTERACTION_0.9.2.json): sidebar whitespace, disclosure/input/state, disabled controls and wrapping independent buttons. |
| 0.9.1 | 128 tests, 22 suites, 19.642s | [82-deployment regression](DEX_REGRESSION_0.9.1.json), TRON two-mode continuation, 13 SUN variants, receipt binding and unknown-state blocking. Independent Node verification was not enabled for this run. |
| 0.9.0 | 122 tests, 22 suites, 18.97s, independent Node enabled | Exact price/identity/decimals, stale/partial/unknown valuation, deduplication, migration/cache; [live](market-live-report.json), [package](market-package-report.json). |
| 0.8.1 | 116 tests, 21 suites, 18.55s, independent Node enabled | BSC exact USDT approvals, reset/Permit2 continuation, all 15 phase outcomes and receipt thresholds; [live](dex-continuation-live-report.json), [package](dex-continuation-package-report.json). |
| 0.8.0 | 111 tests, 20 suites, 17.34s, independent Node enabled | Idle lock, 59 presets/32 networks, 92 icons, asset scope/cache/migrations; [live](assets-live-report.json), [package](assets-package-report.json). |
| 0.7.0 | 106 tests, 19 suites, about 17s, independent Node enabled | Queues/archive/crash recovery/replacements/expiry/notes; [live](transactions-live-report.json), [package](transactions-package-report.json). |
| 0.6.0 | 91 tests, 15 suites, 16.8s | Bridges, random notes, full public Groth16 proof and offline kernel sandbox; [live](bridge-privacy-live-report.json), [packaged proof](privacy-packaged-report.json). |
| 0.5.0 | 82 tests, 13 suites, independent Node enabled | Protocol-specific DEX ABI/deployments, exact/Permit2 approvals, SUN validation, cancellation/concurrency; [read-only DEX](dex-live-report.json). |
| 0.4.0 | 68 tests, ten suites | UTXO proofs/signatures, non-EVM transfer bytes, Monero import/runtime and typed contracts; no funded acceptance. |
| 0.3.0 and earlier | 55 tests, eight suites | BIP39/BIP32, EIP55, exact amounts, signatures/vault/migration/import/network boundaries. |

Reports are version-specific snapshots, not current package hashes. Generated screenshots are not committed; all examples are published fixtures. Old ZIP files were removed from local delivery, while their historical checksums in JSON remain evidence for those historical snapshots.

## Read-only network evidence

The 0.9.1 full catalog run has 84 deduplicated outcomes: 58 deployment/quote/full simulations, four deployment/quote checks, 22 deployment-only checks and zero unresolved probe failures after documented retests. This covers 82 EVM entries and two TRON modes, not liquidity for every token/pool or funded swap success. Initial interrupted/no-liquidity probes remain in the [report](dex-0.9.1-live-report.json).

Price probing checked 141 IDs: 137 usable, 129 within 15 minutes. Missing/historical data retained its actual status. Preset-token probing verified 15 Ethereum/BSC/TRON tokens for identity/code/decimals and public-fixture balance calls. No user holdings were sent to a price provider.

Four USDT bridge directions were quoted through Tor: Allbridge ETH→TRON/TRON→ETH and Stargate ETH→BSC/BSC→ETH. Eight fixed pools passed denomination/levels/verifier checks and public-proof verification. Full pool-history restoration and funded deposits/withdrawals were not accepted.

EVM 0.3.0 probing checked 56 prioritized mainnets plus ETHW: 49 passed, six partial, Flare unavailable (403). Manta/Metis/Morph/Hemi additional fees were incomplete; Abstract/zkSync burn-address gas estimation reverted. See [per-node report](EVM_RPC_REPORT.md), [raw results](evm-rpc-report.json) and [packaged checks](evm-packaged-report.json).

Earlier native balance checks passed for BTC, five transparent LTC profiles, SOL, TRON, APT, TON, NEAR, Stacks, Cardano, Polkadot Ed25519, Cosmos Hub, Osmosis, Celestia, Injective and Sei. Sui's public GraphQL endpoint returned 403 through the tested exit; no direct bypass was used. EOS/WAX/Starknet account-linked live balances and unconfigured Cosmos endpoints were not accepted. MWEB public queries are blocked before networking.

Tor checks reached 100% bootstrap, verified IsTor and Sepolia, and rejected new requests after stopping. Exit IPs were not logged. Endpoint success is time/exit-specific, not a permanent availability claim.

## Independent encodings and local-chain checks

Published fixtures cross-check 24 address/profile families with pinned bitcoinjs/noble/scure/TON/Cardano libraries. ethers 6.15.0 checks EIP-1559/Legacy signed bytes, typed ABI and bridge/proof calls. Taproot Schnorr signatures receive independent verification when VEIL_VERIFY_NODE=1. Development reference dependencies do not ship.

LTC tests include Core valid/invalid encodings, script-only watching, legacy prefix conversion, MWEB indices 0/1/10, invalid points/checksums and vault migration. Monero official offline runtime checks derived addresses and SOCKS4a forwarding; kernel tests allow only the selected proxy port.

Anvil 1.5.1 runs isolated loopback/random-port/no-mining without a fork or upstream: nonce queues, speed-up, cancellation, dropped responses and no duplicate payment. BTC/LTC tests model RBF/CPFP/descendants/conflicts; real mainnet mempool/package acceptance is outstanding. Optional checks skip if dependencies are absent and must not be counted as live-chain acceptance.

The proof helper generated a public-test Groth16 proof under its real macOS sandbox, including after signed Node packaging. Canary reads/writes/network were denied. Secret inputs were not logged. Packaging fixes avoid circular nested-runtime hashes.

## Native macOS and packaging

The macOS vault EPERM issue was isolated to explicit Complete file protection. Atomic encrypted replacement plus 0700/0600 permissions passed vault/password/tamper/migration checks; filesystem protection classes remain OS-controlled.

Native click tests target only our own test window, without system injection/accessibility access. Hover checks inject non-replayed phase signals and sample real background pixels; they are not OS-pointer acceptance. [UI.md](UI.md) records dimensions and limits.

Release validation checks architecture, nested signatures, resource inventories, fixed protocol catalogs, artwork/licenses, absence of test bundles/native addons, local paths and user wallet data. DMG verification mounts read-only and compares App files/permissions/links; source snapshots match the staged tree. Builds remain ad-hoc signed and unnotarized. Packaging does not constitute redistribution clearance.

## Outstanding acceptance

Complete system DNS/TLS/process capture across macOS versions, Intel hardware, hostile-network/sleep/crash matrix, funded testnet native/ERC20/non-EVM flows and recovery, full XMR restore, all self-configured endpoints, mainnet replacement/package policy, privacy-pool funded closure, independent audit, Developer ID/notarization and licensing/supply-chain review remain outstanding. Current behavior is described in [PRODUCT_SCOPE.md](PRODUCT_SCOPE.md), not inferred from older validation snapshots.
