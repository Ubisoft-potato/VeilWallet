# Threat model and security boundaries

This is a development preview without independent security audit or production-funds acceptance. Cryptographic, desktop, supply-chain, network and protocol review remain required.

## Protected data and intent

- Mnemonics, BIP39 passphrases, keys and passwords stay local; no application logging or network upload. Explicit backup copy has a limited clipboard-clearing policy, not protection against other software.
- RPC source IP is routed through the app's own Tor SOCKS proxy, with no direct fallback. Target domains are sent as SOCKS domain names rather than locally resolved.
- Local history, node API keys, prices and balances are encrypted.
- Signing previews show chain, complete recipient/contract, amount, nonce and fees. Only implemented structured encodings are exposed.

## Keys, vault and persistence

BIP39 uses Security randomness, SHA256 checksum, NFKD and CommonCrypto PBKDF2-HMAC-SHA512 with a bundled English list. BIP32 uses HMAC-SHA512 and Bitcoin Core libsecp256k1, rejecting invalid scalars/indices rather than nonstandard modular reduction. Pinned offline OKX/btcd code handles supported multichain encoding behind a bounded serialized C ABI with no network/file/process/logging entry or arbitrary-byte signing. Swift implements derivation policy using pinned upstream primitives.

ECDSA uses upstream deterministic nonces/low-S and randomized context blinding. RLP/Keccak/signatures are cross-checked with independent implementations. No custom cryptographic primitives are introduced.

The vault uses a random 32-byte salt, PBKDF2-HMAC-SHA256 at 600,000 rounds, random-nonce AES-256-GCM and version-bound AAD. Versions, KDF parameters and file sizes are bounded; disk input cannot choose arbitrary iteration counts. Encrypted bytes are atomically replaced, with 0700 directories/0600 files.

Explicit Complete file-protection flags returned EPERM on the tested native macOS environment; filesystem protection classes are left to the OS. App locking releases decrypted references but does not guarantee filesystem unreadability on system lock or reliable zeroization of Swift/CryptoKit/FFI/string copies. Keys remain in memory while unlocked.

Separate local metadata/transaction archives use a random non-syncing Keychain AES key. Vault/password or mnemonic recovery does not depend on that metadata key, but archives/settings do. Every signature, backup display, wallet removal and password change re-authenticates. Password rotation uses a new salt and rolls back memory state on write failure. Watch-only wallets cannot sign.

Before broadcast, save typed intent and signed payload/XMR metadata in UUID/AAD-bound encrypted archives. Persist the broadcast attempt before the network call. Timeout/crash recovery retains unverified state and reservations; no automatic resend. A process-level single-writer lock protects the data directory. See [transaction rules](TRANSACTIONS.md).

Language is a non-sensitive app-local UserDefaults preference with no synchronization. It updates displayed text immediately while retaining forms, passwords, session state and approved previews; it never triggers signing, requoting or broadcasting. Localization only changes display text; canonical IDs/legacy state decoding, amounts, addresses, signing bytes and existing vault schemas remain stable.

## Request boundaries

~~~mermaid
flowchart LR
  UI[Native user action] --> Protocol[Protocol and chain validation]
  Protocol --> Gate[Unlocked and Tor ready]
  Gate --> Curl[CPrivacyTransport libcurl]
  Curl -->|Loopback SOCKS5 with remote DNS| Tor[Bundled Tor process]
  Tor --> Relay[Tor relays]
  Relay --> RPC[HTTPS RPC]
~~~

No URLSession, WebView, WebSocket, remote images or telemetry SDK. libcurl fixes a random loopback socks5h port, clears NOPROXY, disables netrc/HTTP/redirects, verifies certificates/hostnames, requires TLS ≥1.2 and bounds responses/timeouts. Any failed option setup blocks the request.

SecureTransport trust evaluation can cause system trustd certificate fetches. Before global initialization, the app requires OpenSSL/LibreSSL and explicit bundled Mozilla roots, without native CA/AIA/online OCSP/CRL. Missing intermediates or unavailable backend fail closed. Roots require release updates. Future macOS implementations still need system-level capture validation.

obfs4 bridge endpoints accept literal IP/port only, preventing pre-bootstrap hostname DNS. Bridges remain process-local.

Tor runs ClientOnly on a random loopback SOCKS port, without ControlPort/DNSPort/TransPort, with SafeSocks/SafeLogging/IsolateSOCKSAuth. Only its own 100% bootstrap opens the gate. Exit/lock/sleep closes the gate and cancels requests. Guard/consensus state is retained to avoid unnecessary guard changes. Raw Tor logs/exit IPs are not application logs.

### Monero exception

[MONERO.md](MONERO.md) documents fixed local Digest RPC plus an official monero-wallet-rpc process using SOCKS4a to a v3 onion daemon. Kernel sandbox rules deny network/Mach access except local wallet RPC inbound and the selected Tor port outbound; no-dns is enabled. No remote wallet RPC, scan-key upload or direct fallback exists. Secrets cross local RPC and encrypted cache only. Same-user malware remains outside protection. Source checks, proxy forwarding and kernel-port tests do not constitute a full packet-capture audit.

### Offline proof helper

[BRIDGES_PRIVACY.md](BRIDGES_PRIVACY.md) describes a separate bundled Node process. Random Classic notes live in the password vault, not mnemonic derivation, and survive wallet removal. Secrets use stdin, never RPC/argv/logs. Its kernel sandbox denies networking, extra execution and user-file content access/writes; only runtime/system resources, random device and required ancestor metadata are allowed. Native addons are disabled; two-worker/timeout/I/O bounds apply; lock/cancel terminates it.

Deposit self-tests use public test notes, never private commitment/nullifier pairs. Withdrawal downloads full pool events, checks roots/unspent/public inputs/verifier and requires a separate gas-paying signer. Timing/gas/behavior can still link deposits and withdrawals. Only verified canonical failed/cancelled results permit re-authenticated release of matching note sending records; the note remains.

## Protocol boundaries

- Network formats/paths are independent; a Solana key cannot become an EVM signer. Fresh previews expire after 90 seconds. Rebroadcast uses identical archived signatures, with password/account/state/expiry checks, not a new payment.
- EVM/BTC/LTC/TRON/Solana/Sui/Aptos/Starknet/Polkadot validate supported chain identities. Cosmos checks denomination and fixed sending chain ID/key/sequence. TON/NEAR/Stacks/Cardano/EOS/WAX balance trust depends on configured mainnet endpoints; sending is unavailable. All balances depend on nodes, not light-client proofs.
- EOS/WAX permission keys and Starknet public keys are not receive account names/contracts. Manual binding is local metadata, not proof of signing control.
- EVM fees distinguish Legacy/EIP-1559. Priority-fee fallback requires explicit method-not-found, never rate-limit/network errors. OP/Scroll/Mantle ABI and additional fees are checked/re-read. Local 20% buffers are not protocol-enforced caps. Unknown OP versions block; unsupported L2 additions are disclosed. ETHW also verifies genesis because chain ID 10001 is shared with smartBCH testnet.
- Generic contracts accept typed bounded calls, not raw calldata/arbitrary RPC/DApp signing. Simulation can still authorize a malicious contract and does not guarantee future success.
- EVM DEX uses fixed deployments/local encoding without a remote aggregator. SUN's Tor-based routing service learns pair/amount; local policy rejects unknown commands/hooks/referral fees and fixes recipient/minimum output. Exact token and Permit2 approvals are separate. See [DEX limits](DEX.md).
- Bridges use fixed USDT routes and dual-chain GUID/recipient/amount verification. Source confirmation is not delivery. Allbridge proportional slippage is not an absolute minimum. USDT administrators/upgrades/freeze and message execution remain risks.
- LTC validates mainnet/checksum/witness rules and MWEB public points. Old 3… prefixes cannot establish chain intent; equivalent M… is queried. MWEB derivation uses pinned BLAKE3/libsecp256k1; no public balance/scan-key service or MWEB send is implemented.

## Asset and session privacy

Default idle lock is 30 minutes, configurable 1–120; switching apps keeps the session, while secret views hide content. ContinuousClock and activation/interaction/10-second checks enforce expiry; background refresh does not extend it. Sleep/manual lock/exit stop Tor, Monero, proofs and pending requests.

After unlock/Tor, automatic queries use configured scope and at most three tasks. Only derived/bound addresses and configured tokens are queried; no address set is uploaded to an indexer. Nodes still learn queried addresses. XMR full scan is manual; MWEB public queries are prohibited.

Token identities pin chain/contract/decimals; mismatches block numeric display. Issued/bridged/legacy identities stay distinct. Failed queries retain timestamps and stale values rather than zero. Wallet/node/account changes cancel old scans. Icons are bundled from pinned sources, not downloaded at runtime.

USD quotes use fixed coins.llama.fi identifiers plus manually added token contracts, without wallet address/balance/ID. Timing/contracts remain visible to the price provider; separate random isolation is used. BigUInt performs local valuation. Invalid/low-confidence/stale/future values are rejected/labeled. Quotes never enter signing/fee/balance authority.

## Outside protection

Public transaction graphs, same-address cross-chain linkage, amount/timing/fingerprints, node queries, global correlation, colluding Tor relays and recognition of Tor use remain possible. A compromised OS, same-user malware, accessibility/capture/keylogging software, swap/diagnostics/backups and binary/library replacement are outside the model.

Gatekeeper, notarization, Apple services and other apps are not routed/controlled here. No system VPN/DNS change is made. Random ports and child-process ownership reduce accidental collisions, not hostile-user isolation.

The kill switch is application-level fail-closed gating/cancellation, not a system firewall. libcurl cancellation can have scheduling delay. Already sent transactions cannot be recalled.

## Outstanding acceptance

Independent cryptographic/network review; cross-version DNS/TLS/process capture; crash/sleep/proxy failure matrix; hardware signing; memory protection; independent simulations/allowance risk controls; complete remaining protocols/L2 fees; funded transfers/replacements/privacy flows; full XMR recovery; Developer ID/notarization; reproducible builds and supply-chain/redistribution review remain outstanding.
