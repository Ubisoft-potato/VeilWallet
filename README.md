# Veil Wallet

A native, self-custodial macOS wallet built with SwiftUI and AppKit. **0.10.1 is a development preview**, with English as the default interface and Simplified Chinese available in the unlock screen and Settings. Language changes apply immediately, without restarting or clearing forms.

Keys are generated and used locally. Supported network requests use bundled Tor, remote DNS and no direct fallback. Tor does not hide the public transaction graph or protect a compromised Mac. This project has **no independent security audit, production-funds acceptance, Developer ID signature or Apple notarization**.

## Features

- Create or import English BIP39 mnemonics with 12/15/18/21/24 words, an optional BIP39 passphrase, supported private keys or watch-only addresses. Native multi-wallet management, address previews, backup display and password changes.
- A fixed catalog of 81 EVM mainnets, Sepolia, 39 non-EVM networks and Nostr. Import, balance and sending support differ; see the [network matrix](Documentation/PRODUCT_SCOPE.md).
- Native/token balances, offline icons, searchable networks, 59 EVM/TRON token presets, Tor-based USD prices and local portfolio valuation. Missing data stays explicitly unknown.
- Transfers for EVM native coins/ERC20, transparent single-key BTC/LTC, SOL, TRX, APT, 21 Cosmos Bank networks and the official local XMR wallet runtime.
- Typed EVM contract calls, 82 configured EVM DEX deployments and two TRON swap modes, separate exact approvals and confirmed-approval continuation. See [DEX support](Documentation/DEX.md).
- Fixed USDT bridges ETH↔TRON and ETH↔BSC. Classic ETH/BNB privacy pools use separate notes and a bundled offline proof helper. See [scope and limits](Documentation/BRIDGES_PRIVACY.md).
- Encrypted local transaction archives, manual same-payload rebroadcast, EVM nonce queues/replacement/cancellation and BTC/LTC RBF/single-level CPFP. No cloud sync or cross-Mac recovery workflow.
- Configurable idle lock, default 30 minutes. Switching apps keeps the wallet unlocked; sleep, manual lock and exit stop runtimes. Secret-display views hide content when focus leaves.

A catalog entry does not promise that every endpoint, pool or asset remains available. DApp/WalletConnect, hardware wallets, NFTs, arbitrary unknown-token indexing, generic non-EVM token transfer forms and full address-history indexing are not implemented.

## Build

Use Apple Silicon, macOS 14+, Swift 6.1+, Go 1.26.1, Python 3, GnuPG and standard macOS command-line tools. The validated CI toolchain is in [DMG_BUILD.md](Documentation/DMG_BUILD.md). Intel runtime archives exist, but Intel hardware has not been validated.

Run from the repository root. Developer fetch scripts contact upstream services directly to obtain pinned, verified build inputs; they are not wallet runtime requests.

~~~bash
./Scripts/fetch-tor.sh
./Scripts/fetch-monero.sh
./Scripts/fetch-privacy-runtime.sh
./Scripts/swift.sh test
./Scripts/check-privacy.sh
./Scripts/build-app.sh
./Scripts/build-dmg.sh --skip-build
~~~

Run SwiftPM operations sequentially. The wrapper builds the offline Go C archive and handles installed Swift Testing macros. Packaging includes Tor, obfs4 support, CA roots, Monero and the offline Node proof runtime; the running app does not download executables.

Outputs are in build/: Veil Wallet.app, a versioned ARM64 DMG/ZIP, build metadata and SHA256 checksums. The DMG has an Applications shortcut and English instructions. [GitHub Actions](.github/workflows/macos-dmg.yml) builds artifacts without publishing a GitHub Release.

## Tor and local data

Opening the app shows an offline unlock screen. **Tor starts after successful vault unlock**; requests require its own process to report 100% bootstrap. Locking or closing stops Tor and local runtimes. This does not proxy other apps or change system DNS. If bootstrap fails, offline import, backup and address viewing remain available. Settings accepts IP-based obfs4 bridges for the current process.

Ordinary requests use TorTransport → CPrivacyTransport → socks5h, HTTPS port 443, bundled CA verification and no redirects. Monero has an explicit exception: fixed authenticated loopback wallet RPC and a kernel-restricted official process connecting only to the selected Tor port via SOCKS4a and a v3 onion daemon.

Vault and encrypted local records live in the user's **Application Support → VeilWallet** directory. Removing the App normally leaves that data and local Keychain intact. Deleting either can lose records. Random privacy notes are in the password vault and **cannot be recovered from a mnemonic**. See [data and recovery limits](Documentation/TRANSACTIONS.md).

Language is a non-sensitive app-local UserDefaults preference, without sync. Other preferences/caches remain encrypted locally.

## Import compatibility

BIP39 uses the English word list. TON-native, Electrum, SLIP39 and Chinese-word mnemonics are not accepted. Sui/Aptos support Ed25519; Polkadot uses the explicitly labeled Ed25519 BIP44 scheme, not sr25519/SURI. Cardano uses CIP-1852; its private-key entry requires a 128-byte payment/stake extended-key pair. NEAR derives implicit accounts. EOS/WAX and Starknet need explicit on-chain account binding.

XMR can derive from this BIP39 wallet using the Ledger-compatible path, or import a supported native 25-word seed/spend key. Other wallets may use different BIP39-to-XMR conventions. LTC validates/watches all Core mainnet address encodings; arbitrary scripts and MWEB remain receive/watch-only. See [Litecoin](Documentation/LITECOIN.md), [Monero](Documentation/MONERO.md) and [transfers](Documentation/TRANSFERS.md).

Always compare the import preview to your existing address. A valid mnemonic does not prove that its path, passphrase, account index or contract version matches the original wallet.

## Development and publication

Read [CONTRIBUTING.md](CONTRIBUTING.md), the [threat model](Documentation/SECURITY.md), [validation records](Documentation/VALIDATION.md) and [publication audit](Documentation/OPEN_SOURCE_AUDIT.md). Tests/previews use published disposable fixtures; never fund those accounts. Screenshots, runtime downloads, caches and wallet data are excluded from Git.

Original work uses [MIT](LICENSE). Third-party code keeps its licenses, including GPL/LGPL requirements; see [NOTICE.md](NOTICE.md) and [components](Documentation/THIRD_PARTY.md). [SECURITY.md](SECURITY.md) describes vulnerability reporting.

~~~text
Sources/VeilWallet/          Native UI and session coordination
Sources/WalletCore/          Vault, derivation, transport and protocol adapters
Sources/CPrivacyTransport/  External request boundary
Sources/CChainCore/         Offline C ABI
Native/ChainCore/            Pinned offline Go SDK wrapper
Vendor/OKXWalletSDK/         Upstream subset and licenses
Tools/                      Developer tools and public-fixture smoke checks
Tests/                      Protocol, privacy, localization and tooling checks
Scripts/                    Build, audit and packaging tools
Configuration/              App configuration, provenance and licenses
Documentation/              English product and security documentation
~~~

Research used [OKX wallet management](https://www.okx.com/en-us/help/how-do-i-manage-my-wallet-web) and [network documentation](https://web3.okx.com/onchainos/dev-docs/wallet/supported-networks). Veil Wallet is independent, does not implicitly run OKX services and does not claim feature equivalence.
