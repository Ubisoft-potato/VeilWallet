# Third-party components

0.6.0 adds a separate offline PrivacyRuntime bundle: official Node 24.22.2 (MIT and bundled NODE-LICENSE notices), fixed Tornado CLI circomlib/snarkjs/websnark commits and fixed-merkle-tree 0.6.1. The adapter and packaging additions are GPL-3.0-or-later. Loaded source packages, original licenses, circuit sources, lockfile and build scripts are included in the helper. DEPENDENCIES.json inventories 27 collected packages; provenance/ORIGINS.json pins the signed Node archive, circuit/proving-key SHA256 and Git blobs. The native wallet communicates through JSON stdin/stdout, without linking those libraries. See [implementation and license boundary](../Vendor/PrivacyRuntime/source/NOTICE.md). No Node or proof code is downloaded by the running app. Use the recorded upstream published trusted setup; no cryptographic primitives were rewritten. Version 0.10.2 patches bn.js 4.x to 4.12.3 and replaces the pinned snarkjs entry with a hash-verified prover-only export list. Legacy JavaScript verifier/setup/prover and CLI code is physically excluded; the upstream field/curve/witness primitives and canonical circuit artifacts remain unchanged. LOAD_GRAPH.json and MODIFICATIONS.json record the runtime subset and entry change. See [dependency remediation](DEPENDENCIES.md).

Swift versions are pinned in Package.swift and Package.resolved. Go dependencies are pinned in Native/ChainCore/go.mod and go.sum; local SDK modules are pinned by Vendor/OKXWalletSDK/UPSTREAM_COMMIT. Keep upstream license and notice files with distribution.

| Component | Version | Use | License / source |
|---|---|---|---|
| 21-DOT-DEV/swift-secp256k1 | 0.24.0 | Bitcoin Core libsecp256k1, public keys and recoverable low-S ECDSA | MIT; bundled Swift Crypto notices also apply; https://github.com/21-DOT-DEV/swift-secp256k1 |
| CryptoSwift | 1.10.0 | Keccak-256 | Project license (attribution/notice); https://github.com/krzyzanowskim/CryptoSwift |
| attaswift/BigInt | 5.7.0 | Exact integer amounts, RLP quantities | MIT; https://github.com/attaswift/BigInt |
| Apple CryptoKit / CommonCrypto / Security | system | AES-GCM, HMAC, SHA256/512, PBKDF2, secure randomness, local Keychain | Apple platform SDK |
| Apple libcurl | system | SOCKS5-hostname + HTTPS through explicitly selected OpenSSL/LibreSSL backend | curl / LibreSSL / system notices |
| Tor Expert Bundle | 16.0; Tor 0.4.9.15 | Child process, SOCKS5 remote DNS, obfs4 via lyrebird | Tor BSD-3-Clause; bundled components retain their own notices in Helpers/TorRuntime.bundle/Contents/Resources/docs; https://www.torproject.org/download/tor/ |
| OKX Go Wallet SDK | commit `89c5153f4669b0d81658b37bae902b62d495d574` | Offline multi-chain account/address library, vendored source subset; C archive, no runtime service | Root MIT; embedded components retain their own licenses; https://github.com/okx/go-wallet-sdk |
| lukechampine.com/blake3 | 1.2.1; cpuid/v2 2.0.9 | Offline MWEB subaddress BLAKE3, pinned to ltcsuite reference version | MIT; notices bundled in Licenses/ChainCore; https://github.com/lukechampine/blake3 |
| Go runtime and module dependencies | toolchain recorded in Licenses/ChainCore/Go/VERSION; module versions in modules.json | Statically linked local crypto only | BSD/MIT/Apache/CC0 and other upstream notices in Configuration/Licenses/ChainCore |
| go-ethereum and vendored derivative | v1.17.10 and fixed OKX crypto subtree | secp256k1/public-key and protocol helpers | LGPL-3.0 library / upstream COPYING and COPYING.LESSER; https://github.com/ethereum/go-ethereum |
| BIP39 English word list | upstream standard | Mnemonic generation/validation | https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt |
| Mozilla CA bundle | 2026-10-20 snapshot | Offline TLS trust roots | MPL-2.0; https://curl.se/docs/caextract.html |
| Monero wallet RPC | 0.18.5.4 official macOS archive | Separate local wallet process: scanning / RingCT / signing; sandboxed Tor-only daemon access | BSD-3-Clause and bundled dependency notices; MoneroRuntime.bundle/Contents/Resources/LICENSE; https://www.getmonero.org/downloads/ |
| Monero English word list | v0.18.5.4 english.h; Git blob 1715445d89380578d2605053f04510b3048470e0 | Native 25-word seed decoding | BSD-3-Clause; Configuration/Licenses/MoneroWordlist; https://github.com/monero-project/monero/blob/v0.18.5.4/src/mnemonics/english.h |
| filippo.io/edwards25519 | fixed in Native/ChainCore/go.sum | Constant-time Monero scalar / public key operations | BSD-3-Clause; bundled Go notices; https://github.com/FiloSottile/edwards25519 |

CA bundle SHA-256: `796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe`.
BIP39 and cryptographic primitives run entirely offline. ethers 6.15.0 is only an optional development reference and is never linked or shipped.

Tor archive integrity:

- aarch64 SHA-256: `b8da251eccbe9e82f3681ee3af3c97fb4291c4a4e153e5b824bde48a1117cd6a`
- x86_64 SHA-256: `5b1860215c26f2d408392d1d79e798a2f81d65eb939510bb94c11f237bd0bfc3`
- Pinned Tor Browser Developers primary signing-key fingerprint: `EF6E286DDA85EA2A4BA7DE684E2C6E8793298290`.
- ARM64 archive signature verified against subkey `022DA248432D2A0E0F54E65E316C1FACD62D07D9`, signature date 2026-10-29. Hash/signature are checked before local code-signature replacement.
- Tor is an independent executable, not linked into WalletCore. Preserve upstream corresponding-source availability and license obligations when distributing the bundle. The pinned official release and its build definitions are available at https://archive.torproject.org/tor-package-archive/torbrowser/16.0/ and https://gitlab.torproject.org/tpo/applications/tor-browser-build .


## Multichain provenance and redistribution

Selected SDK modules are copied unmodified under Vendor/OKXWalletSDK. Local validation and FFI policy live separately in Native/ChainCore/main.go. Scripts/build-chain-core.sh builds a local C archive with the gofuzz,purego build tags: geth uses its pure-Go secp256k1 implementation, avoiding duplicate C symbols, and dependencies select their upstream portable implementations to avoid embedding assembler checkout paths. These are upstream implementations, not local cryptographic rewrites. The tags and archive options are included in the build fingerprint.

Scripts/collect-go-licenses.py enumerates the modules actually compiled into the archive and preserves their license/notice files, including nested licenses and embedded geth LGPL notices. The App packages this directory. The manifest is Configuration/Licenses/ChainCore/modules.json. Developer tools do not become network clients inside the wallet.

Development binary releases include exact corresponding sources, modifications, build instructions and replacement/relink evidence under the [release policy](RELEASE_POLICY.md). Statically linked LGPL components retain their source and relinking rights. Vendored fork sources are in this tree; external compiled module sources and Go runtime sources accompany the release. The bundled Tor notice identifies Tor as BSD-3-Clause; its GPL Autoconf macro notice explicitly covers a file not compiled into Tor. Upstream component notices remain bundled, and pinned Tor source/build recipes are delivered as well. Do not relabel all transitive code as MIT. These materials do not constitute a legal opinion or an independent security audit.

Independent test vectors are generated by Scripts/verify-multichain.cjs using pinned development-only @noble/curves 1.9.7, @noble/hashes 1.8.0, @scure/base 1.2.6, @scure/bip32 1.7.0, @scure/bip39 1.6.0, @scure/starknet 1.1.0, bitcoinjs-lib 6.1.7, tiny-secp256k1 2.2.3, @ton/ton 15.4.0, @ton/crypto 3.3.0 and Cardano Serialization Lib 15.0.3. They are not shipped in the App. The fixture mnemonic and private keys are public standard test data, never funded or used for real wallets.

Litecoin parameters and address encoding follow litecoin-project/litecoin key_io.cpp and chainparams.cpp. Core valid/invalid address test data is preserved under Tests/WalletCoreTests/Fixtures/litecoin-core-addresses.json; MWEB subaddress vectors are from ltcsuite/ltcd/ltcutil/mweb/keychain_test.go and ltcsuite/ltcwallet/waddrmgr/mweb_compat_test.go. Reference source URLs are recorded in Documentation/LITECOIN.md. These public test keys are not shipped in the application.

## Offline artwork

Public PNGs come from pinned commits of Trust Wallet assets (MIT), spothq cryptocurrency-icons (CC0) and Erik Thiart cryptocurrency-icons (MIT). [ASSET_ARTWORK.json](ASSET_ARTWORK.json) records source URLs, revisions and SHA256. Licenses stay in Configuration and the packaged App. Trademarks remain with their owners; icons do not establish endorsement, asset authenticity or investment suitability. No runtime artwork requests occur.
