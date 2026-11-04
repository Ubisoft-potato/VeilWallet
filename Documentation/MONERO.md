# Monero / XMR

## Import and recovery

BIP39 wallets derive XMR using the [Ledger-compatible](https://github.com/LedgerHQ/app-monero/blob/master/src/monero_init.c) path m/44'/128'/{i}'/0/0: BIP32 secp256k1 child key → Keccak256 → Ed25519 scalar reduction for the spend key, then derived view key. Independent vectors and the official offline runtime verify this convention. Other BIP39-to-XMR extensions may differ; compare addresses before recovery.

The private-key entry also accepts a canonical nonzero 32-byte primary spend key or an English native 25-word Monero seed with checksum. Native seeds and BIP39 are separate inputs. No 13/14/16-word seeds, other word lists, view-only wallets, multisig, account/subaddress management. Mainnet standard/integrated/subaddresses validate; current derivation/scanning/spending targets account 0, address index 0.

Balance querying starts the local wallet and scans daemon blocks; no public-address balance API exists. Restore height defaults to zero and may take a long time. Increase it only if the wallet was created after that height; an incorrect height misses older outputs. Balance stays unknown before synchronization. App switching keeps scanning active; sleep/idle lock stops it. Automatic asset discovery never initiates full XMR recovery.

## Bundled runtime and cache

Official monero-wallet-rpc 0.18.5.4 architecture-specific binaries are bundled. Fetching verifies pinned archive SHA256, official signed hashes and binaryFate fingerprint 81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92 before extraction. Runtime downloads are unnecessary; no remote wallet service or user-installed Monero is used.

Caches are isolated by wallet UUID/restore height and encrypted with a high-entropy spend-key-derived password. Directories use 0700, configuration 0600. Secrets traverse only authenticated local RPC, never argv/logs/daemon queries. RPC binds a random loopback port with random Digest credentials. Same-user malware and compromised systems remain outside protection.

## Explicit network exception

Ordinary adapters use CPrivacyTransport HTTPS 443/SOCKS5h. Official Monero handles daemon HTTP using SOCKS4a, requiring a separate boundary.

Swift's dedicated C entry fixes the URL to authenticated loopback JSON-RPC, without an external URL argument. sandbox-exec denies all network and Mach lookups except local RPC inbound and the selected Tor SOCKS port outbound. no-dns/no-initial-sync/untrusted-daemon are set; auto_refresh is disabled before wallet loading. Wallet/runtime logs are disabled.

Only full v3 onion daemon names with explicit ports are accepted. No clearnet HTTP, remote wallet RPC, key upload or direct fallback. Tor encrypts onion HTTP to the hidden service. The default comes from [Cake Wallet's public list](https://github.com/cake-tech/cake_wallet/blob/main/assets/node_list.yml); users may replace it in Settings. Daemons remain untrusted and may refuse service or analyze timing.

Unlock/Tor bootstrap are prerequisites. Tor loss, lock, exit or wallet change stops the process. SOCKS4a domain forwarding and kernel-port restrictions were locally tested; full system packet-capture acceptance remains outstanding.

## Transfer flow

1. Synchronize unlocked balance, then enter a mainnet recipient/amount.
2. Verify vault password to authorize local construction/signing with do_not_relay=true. This does not broadcast.
3. Show actual amount, fee, recipient and hash; preview expires in 90 seconds.
4. Re-authenticate to broadcast. Persist hash/metadata first, then relay_tx. Timeout stays unverified; no automatic retry.

RingCT, input selection and signatures use the pinned official runtime, not custom Monero cryptography. Full initial live recovery and funded end-to-end transfer acceptance remain uncompleted.

Sources: [wallet RPC](https://www.getmonero.org/resources/developer-guides/wallet-rpc.html), [proxy documentation](https://github.com/monero-project/monero/blob/v0.18.5.4/docs/proxies.md), [signed hashes](https://www.getmonero.org/downloads/hashes.txt).
