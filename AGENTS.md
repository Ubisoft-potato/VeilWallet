# Veil Wallet development

- Native macOS SwiftUI/AppKit application; Swift Package Manager project, macOS 14 minimum.
- Read README.md and Documentation/SECURITY.md before modifying key storage, signing or networking.
- All runtime external requests must pass through WalletCore TorTransport and CPrivacyTransport. No URLSession, WebView, remote images, external browser, WebSocket, telemetry or direct fallback without an explicit architecture change and leakage validation.
- Do not log private keys, mnemonics, BIP39 passphrases, passwords, raw signed transactions, wallet addresses or Tor exit IPs.
- Use integer amounts (BigUInt), validate chain ID, nonces, destination checksum, fees and preview expiry; never silently guess missing RPC results.
- Do not implement cryptographic primitives from scratch. Use pinned libsecp256k1, CryptoKit/CommonCrypto and CryptoSwift; verify against standard and independent vectors.
- Changes to the network boundary require Scripts/check-privacy.sh, relevant tests and TorSmoke where network access permits.
- Run Scripts/swift.sh test and Scripts/build-app.sh. On this CLT installation, tests use the installed Swift Testing framework through SwiftPM swiftbuild. Build/test operations must be sequential.
- The built app is an ad-hoc signed development build. Do not describe it as audited, fully anonymous, feature-equivalent to OKX, or production-ready.
- Keep unimplemented protocol features explicitly labeled. Do not create sample balances, placeholder signing or fake broadcast successes in production flows.
