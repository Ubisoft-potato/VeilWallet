# Dependency remediation and runtime scope

Version 0.10.2 updates the native dependency graph and makes advisory checks repeatable. No custom cryptographic primitive, wallet data format or canonical privacy circuit/trusted-setup artifact is introduced.

## Native crypto and toolchain

Go 1.26.11 resolves the standard-library version match for [GO-2026-6859](https://vuln.go.dev/ID/GO-2026-6859.json). Both the developer wrapper and CI select this patched toolchain; the full online advisory gate remains enabled.

- [Toolchains.json](../Configuration/Toolchains.json) pins Go 1.26.11. [go.sh](../Scripts/go.sh) selects it for builds, license collection and build metadata without modifying user-wide settings. Missing developer toolchains are downloaded with Go checksum-database verification into the project cache.
- The [Go module files](../Native/ChainCore/go.mod) pin edwards25519 1.2.0, geth 1.17.10, gnark-crypto 0.22.0, current x/sys and the upstream x/crypto change that removes the unmaintained OpenPGP package. Module sums remain checked. The vendored OKX SDK subtree remains unchanged.
- Existing independent public signing/derivation fixtures, local transaction integration and official offline Monero tests verify compatibility. These tests do not replace independent cryptographic review.

## Prover-only legacy compatibility boundary

The deployed Classic circuit uses a fixed historical proving stack. Upgrading that entire stack or generating a new trusted setup would change protocol compatibility. Instead:

1. bn.js 4.x is pinned to the patched 4.12.3 release through a locked override.
2. The pinned snarkjs 0.1.20 entry is checked against its original SHA256, then replaced with the [prover-only export list](../Tools/PrivacyProof/snarkjs-prover-entry.cjs).
3. Original field/curve/witness/serialization implementations and websnark WASM perform proof generation. Legacy JavaScript verifier/setup/prover and CLI files are physically excluded from the runtime.
4. Complete public-fixture proof generation must succeed. LOAD_GRAPH.json records observed module loads; MODIFICATIONS.json records the entry replacement. Neither file contains user notes.
5. [PrivacyDependencyPolicy.json](../Configuration/PrivacyDependencyPolicy.json) binds the adapter, restricted entry and native on-chain-verification boundary to exact file hashes. Changing any boundary invalidates the review.

[GHSA-xp5g-jhg3-3rg2](https://github.com/advisories/GHSA-xp5g-jhg3-3rg2) describes the upstream JavaScript verifier/public-signal issue. That affected verification code is absent from this runtime; the wallet checks bounded public inputs and invokes the deployed verifier through the native adapter. The reviewed disposition is affected_code_not_present for this exact package/version/advisory and verified source boundary. Unknown advisories are not exempted.

## Reproduce the checks

After fetching the verified runtimes and building the native graph:

~~~bash
python3 Scripts/check-dependencies.py --policy-only
python3 Scripts/check-dependencies.py --offline-runtime
python3 Scripts/check-dependencies.py --report build/DEPENDENCY-CHECK.json
~~~

- policy-only verifies source review hashes without downloading/executing dependencies.
- offline-runtime additionally checks collected package entries and excluded code; it does not refresh advisory data.
- The full check queries OSV using public names/versions for actually compiled Go modules, the pinned Go standard library and collected runtime packages. It rejects incomplete/service-error responses and unresolved advisories. Reports contain package/version/advisory metadata, not wallet data.

The macOS workflow runs the full check; local App packaging verifies the restricted runtime offline. These are developer tools. The installed wallet does not query vulnerability databases or fetch executable dependencies.

## Development lockfile versus packaged code

The frozen upstream npm packages still declare historical CLI/linter/build dependencies. A whole-lockfile npm audit can report those packages even when they are neither loaded nor collected into the App. Installation disables lifecycle scripts; the collection proof uses public fixtures only. Native addons and unrelated tools are excluded.

Do not report whole-lockfile counts as exploitable App vulnerabilities or describe them as silently fixed. The runtime gate checks the actual collected graph and admits only the one exact, code-exclusion disposition above. A newly loaded affected package or new advisory fails the gate. Do not use npm audit fix --force against the canonical proof stack or add broad package/folder exceptions.

Retain these scope distinctions in public reports. Binary upload additionally follows the [source/relink delivery policy](RELEASE_POLICY.md); a dependency-check pass is not permission to distribute unreviewed binary materials.
