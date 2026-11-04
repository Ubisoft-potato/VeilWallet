# Key material and public-fixture inventory

Reviewed on 2026-11-04. **Public test keys and seed phrases are not confined to Tests.** They also occur in developer reference scripts, the DEBUG preview renderer and upstream examples. No unexplained user key, user seed, private-note backup or live credential was identified in the reviewed publication trees.

This inventory records locations and purpose, without copying key/phrase/note values. Public fixtures are compromised by design: never use their accounts for funds, recovery or personal privacy notes.

## First-party test material

| Location | Material and purpose |
|---|---|
| [multichain-reference.json](../Tests/WalletCoreTests/Fixtures/multichain-reference.json) | Published BIP39 standard phrase and derived import-format fixtures: WIF, encoded Ed25519 keys/keypairs, Nostr and supported multichain formats. |
| [transfer-reference.json](../Tests/WalletCoreTests/Fixtures/transfer-reference.json) | Deterministic signing inputs/outputs, public-fixture Monero spend/view keys and native seed. |
| [CryptoTests.swift](../Tests/WalletCoreTests/CryptoTests.swift) | BIP32/BIP39/Ethereum vectors, deterministic small-scalar keys and invalid-key cases. |
| [LitecoinTests.swift](../Tests/WalletCoreTests/LitecoinTests.swift) | Public BIP39/Litecoin/MWEB vectors and synthetic vault password. |
| [MultichainTests.swift](../Tests/WalletCoreTests/MultichainTests.swift), [NativeBalanceTests.swift](../Tests/WalletCoreTests/NativeBalanceTests.swift) | Fixture imports, repeated-byte keys, scalar inputs and synthetic passphrases/passwords. |
| [AssetExperienceTests.swift](../Tests/WalletCoreTests/AssetExperienceTests.swift), [VaultTests.swift](../Tests/WalletCoreTests/VaultTests.swift) | Public mnemonic and disposable vault/password tests. |
| [TransactionManagementTests.swift](../Tests/WalletCoreTests/TransactionManagementTests.swift), [TransactionDevchainTests.swift](../Tests/WalletCoreTests/TransactionDevchainTests.swift) | Constructed public signing keys; isolated local-chain accounts and disposable metadata encryption keys. |
| [TransferTests.swift](../Tests/WalletCoreTests/TransferTests.swift), [TronDexTests.swift](../Tests/WalletCoreTests/TronDexTests.swift) | Reference-fixture key material, deterministic TRON account and synthetic runtime passwords. |
| [PrivacyRuntimeTests.swift](../Tests/WalletCoreTests/PrivacyRuntimeTests.swift) | Constructed public privacy-note preimages, signing key and disposable password tests. No user note. |
| [MarketPriceTests.swift](../Tests/WalletCoreTests/MarketPriceTests.swift) | A repeated-byte local-store encryption test key; not a funded wallet key. |
| [PrivacyTests.swift](../Tests/WalletCoreTests/PrivacyTests.swift), [SourceAudit tests](../Tests/SourceAudit/test_audit_source.py), [Packaging tests](../Tests/Packaging/test_packaging.py) | Synthetic credential URLs/tokens and key-block markers used to test rejection. Markers are not complete publisher/private signing keys. |

These are test inputs, not default accounts or recovery fallbacks. Swift test fixtures/resources are excluded from the packaged App. See [fixture provenance](THIRD_PARTY.md) and the [Litecoin references](LITECOIN.md).

## Material outside Tests

| Location | Classification | Packaged behavior |
|---|---|---|
| [verify-ethereum.cjs](../Scripts/verify-ethereum.cjs) | Constructed scalar and public BIP32 seed for independent signature/derivation verification. It can output reference private-key bytes. | Developer-only; not shipped. Its output must remain public-fixture data. |
| [verify-multichain.cjs](../Scripts/verify-multichain.cjs), [verify-transfers.cjs](../Scripts/verify-transfers.cjs) | Public standard phrase and deterministic keys used to regenerate the two reference JSON fixtures. | Developer-only; not shipped. Do not substitute a personal phrase or key. |
| [TorSmoke.swift](../Tools/TorSmoke/TorSmoke.swift) | Public standard phrase for explicitly selected read-only balance probes. | Separate developer executable; not bundled in Veil Wallet.app. |
| [PreviewRenderer.swift](../Sources/VeilWallet/PreviewRenderer.swift) | Public standard phrase, synthetic transaction hashes and illustrative balances for native product previews. | Entire renderer is guarded by DEBUG; Release has no preview entry point. |
| [PrivacyProofRuntime.swift](../Sources/WalletCore/Networking/PrivacyProofRuntime.swift), [PrivacyPoolClient.swift](../Sources/WalletCore/Networking/PrivacyPoolClient.swift), [proof adapter](../Tools/PrivacyProof/main.cjs) | Intentionally public zero-preimage prover self-test. This is a public test note/proof, not a wallet signing key or a user's deposit note. | Deliberately available in Release to check the pinned prover. Real note creation uses secure randomness in [PrivacyPool.swift](../Sources/WalletCore/Models/PrivacyPool.swift). |

The renderer keeps its public fixture close to its DEBUG-only entry point. Developer scripts retain independent reference implementations. Upstream files remain unchanged for provenance. This inventory centralizes review without moving those values into production code or rewriting third-party source.

## Upstream examples and other apparent secrets

The pinned [OKX SDK subtree](../Vendor/OKXWalletSDK) retains public upstream test vectors, examples, documentation and cryptographic constants. Private-key-looking examples also appear outside files ending in _test.go, including these readmes:

- [Bitcoin](../Vendor/OKXWalletSDK/coins/bitcoin/README.md)
- [NEAR](../Vendor/OKXWalletSDK/coins/near/README.md)
- [Stacks](../Vendor/OKXWalletSDK/coins/stacks/README.md)
- [Sui](../Vendor/OKXWalletSDK/coins/sui/README.md)
- [TRON](../Vendor/OKXWalletSDK/coins/tron/README.md)

Other examples include upstream [BIP32 data](../Vendor/OKXWalletSDK/crypto/data/bip32.txt), [HD-key documentation](../Vendor/OKXWalletSDK/crypto/btcd/v2/btcutil/hdkeychain/doc.go) and upstream crypto/coin test files. Public provenance does not make these accounts suitable for funds. The recorded upstream revision is in [UPSTREAM_COMMIT](../Vendor/OKXWalletSDK/UPSTREAM_COMMIT).

Distinguish these from non-secret data:

| Data | Meaning |
|---|---|
| BIP39/Monero dictionaries and upstream word lists | Complete public dictionaries, not a user's ordered seed phrase. |
| Tor/Monero signing keys and Node release keyring | Public release-verification keys, not publisher private keys. |
| CA certificates, SHA256 values, signing fingerprints | Public trust/provenance material. A 32-byte hex match alone does not identify a wallet key. |
| Curve parameters, PKCS8 headers, contract addresses, transaction hashes | Public protocol/encoding data. |
| Translation labels mentioning password/secret and the Secret Network chain ID | Public UI/protocol strings, not stored credentials. |
| [README screenshots](../Assets/Readme/README.md) | Reviewed public-fixture accounts and illustrative values; no seed, backup or private-note view. |

## Real wallet data is runtime data

User material is created/imported at runtime, not written into the source tree. The following locations are relative to the user's **Application Support → VeilWallet** directory:

| Location | Contents/protection |
|---|---|
| vault.json | Password-encrypted wallet material, optional BIP39 passphrases and random privacy-pool notes. |
| local.sealed | Encrypted settings, balances and local metadata. |
| Transactions/*.sealed | Encrypted signed transaction/replay archives. |
| PrivacyTrees/*.sealed | Encrypted pool-event tree caches. |
| Monero/ | Local Monero runtime/cache files; treat as sensitive runtime data. |

The metadata/archive encryption key is separately generated and stored in the non-syncing macOS Keychain under service app.veilwallet.local-data, account metadata. It is not a hardcoded source key. User-exported backups can exist wherever the user saves them; they are outside this source inventory. See [VaultStore.swift](../Sources/WalletCore/Persistence/VaultStore.swift), [LocalStore.swift](../Sources/WalletCore/Persistence/LocalStore.swift) and the [security model](SECURITY.md).

No user Application Support directory, Keychain item or exported personal backup was opened, decrypted or uploaded for this review.

## Repeat and maintain the review

~~~bash
python3 -B Scripts/audit-source.py --source index --report build/key-material-review/index.json
python3 -B Scripts/audit-source.py --source head --report build/key-material-review/head.json
python3 -B Scripts/verify-app.py "build/Veil Wallet.app"
~~~

Reports contain path/rule/line/hash metadata, never matched secret values. In this review, tracked worktree bytes matched the audited index; the original review had one initial committed content tree; the repeatable history scanner now covers every reachable committed tree. A project-only filename inventory also checked ignored local files without following symlinks. Do not generalize a HEAD scan to future history containing older deleted secrets.

[SourceAuditAllowlist.json](../Configuration/SourceAuditAllowlist.json) is the machine-readable record of reviewed candidates, bound to exact file hashes and named rules. There is no folder-wide Tests/Vendor exemption. Neither a rule match nor a reviewed-finding count is a count of private keys. Constructed/repeated-byte fixtures may not appear as contiguous key literals and require source review too.

Keep reports local. For any new unexplained candidate, establish its origin before publication; remove accidental material rather than adding an exception. A scan cannot prove absence of every arbitrary encoding or hidden secret. See [source-publication review](OPEN_SOURCE_AUDIT.md) and [CONTRIBUTING.md](../CONTRIBUTING.md).
