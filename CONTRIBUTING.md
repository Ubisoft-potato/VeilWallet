# Contributing to Veil Wallet

Thank you for helping improve a native, self-custodial macOS wallet. Useful contributions include UX/accessibility fixes, English/Chinese translations, protocol correctness, reproducible public fixtures, privacy validation and clear documentation.

Veil Wallet is a development preview without independent security audit or production-funds acceptance. Start with [AGENTS.md](AGENTS.md), the [security model](Documentation/SECURITY.md) and the [feature matrix](Documentation/PRODUCT_SCOPE.md). Describe implemented and verified behavior separately from planned work.

## Before you start

For a new chain, signing format, network surface or large product change, open a design discussion/issue before substantial implementation. Explain the user problem, protocol sources, intended scope and validation. Small fixes and documentation improvements can go straight to a focused pull request.

For a bug report, include app/macOS version, expected and actual behavior, minimal steps and sanitized error identifiers. Reproduce with a disposable public fixture. **Never include real seeds, keys, passwords, privacy notes, node credentials, signed payloads or personal account screenshots.** Security issues follow [SECURITY.md](SECURITY.md), not public reproduction details.

## Set up a development checkout

Use Apple Silicon/macOS 14+, Xcode or Command Line Tools with Swift 6.1+, Go 1.26.10, Python 3, Node/npm, GnuPG and the tools listed in the [README](README.md#developer-prerequisites). See [DMG_BUILD.md](Documentation/DMG_BUILD.md) for the pinned CI environment.

Run from the repository root:

~~~bash
./Scripts/fetch-gitleaks.sh
git config --local core.hooksPath .githooks

./Scripts/fetch-tor.sh
./Scripts/fetch-monero.sh
./Scripts/fetch-privacy-runtime.sh
~~~

The scanner lives in ignored .tools/gitleaks/. **Local commit hooks do not download it automatically**; missing tools block the check. CI explicitly downloads/verifies the pinned scanner. No scanner service receives repository contents.

Runtime fetch scripts verify pinned upstream inputs. They are developer bootstrap tools; runtime wallet traffic must retain the Tor boundary. Downloaded runtimes/dependencies do not belong in Git.

Create a focused branch:

~~~bash
git switch -c fix/short-description
~~~

Use a public Git author name/email that you are comfortable publishing, such as your GitHub noreply address. Review your configured identity locally before committing. Scanning does not redact author metadata, remotes or commit messages.

## Build and run

~~~bash
./Scripts/swift.sh test
./Scripts/check-privacy.sh
./Scripts/build-app.sh
open "build/Veil Wallet.app"
~~~

Run SwiftPM operations sequentially. The wrapper builds the offline Go C archive and handles the installed Testing macros. For a verified installer:

~~~bash
./Scripts/build-dmg.sh --skip-build
~~~

Do not use a real vault for development or fund a published test account. Native preview tools use an in-memory/public-fixture model. A local test pass is not funded-chain or system-wide leakage acceptance.

Use the [key-material inventory](Documentation/KEY_MATERIAL.md) to locate existing public fixtures and distinguish them from real runtime wallet data. It also covers developer scripts, DEBUG previews and upstream examples outside Tests; do not copy a personal wallet into any of those locations.

## Choose checks for your change

| Change | Required validation |
|---|---|
| Swift UI, core, signing or persistence | Swift suite, relevant regression cases and App build; inspect affected native views |
| Network/proxy boundary | Privacy source guard, affected transport/sandbox tests and applicable read-only TorSmoke checks |
| Translations | Matching native catalogs, placeholder/key checks and live language switching |
| Documentation/images | English primary text, portable links, public-fixture image review and source scan |
| Cleanup/distribution | Packaging unit tests, App verification and read-only-mounted DMG comparison |
| New protocol/DEX adapter | Official deployment/encoding sources, independent vectors, wrong-chain/error cases and clearly scoped live validation |

### Fast local checks

~~~bash
python3 -m unittest discover -s Tests/SourceAudit -p 'test_*.py'
python3 -m unittest discover -s Tests/Packaging -p 'test_*.py'
python3 -m unittest discover -s Tests/Localization -p 'test_*.py'
python3 Tools/Localization/catalog.py --check
python3 Scripts/check-documentation.py
python3 Scripts/check-documentation.py --source index
python3 Scripts/check-dependencies.py --policy-only
./Scripts/check-privacy.sh
~~~

### Optional deeper checks

Anvil integration uses an isolated literal-loopback chain with a random port, no mainnet fork and public disposable keys. If Anvil is absent the optional case skips; do not count that as a completed integration run.

~~~bash
VEIL_ANVIL="$(command -v anvil)" ./Scripts/swift.sh test
~~~

Independent signature-reference checks require their pinned development dependencies and VEIL_VERIFY_NODE=1. They are not enabled by default CI. Follow the existing scripts/tests and record which optional checks actually ran. See [VALIDATION.md](Documentation/VALIDATION.md), [TRANSACTIONS.md](Documentation/TRANSACTIONS.md) and [PRIVACY_TESTING.md](Documentation/PRIVACY_TESTING.md).

Run only read-only TorSmoke probes on public fixtures unless a separately authorized test plan calls for disposable test-network transactions. Do not sign or send mainnet funds to validate a PR.

## Implementation expectations

### Preserve the privacy boundary

All runtime external requests use WalletCore TorTransport/CPrivacyTransport, with the documented Monero exception. Preserve unlock/bootstrap gates, remote DNS, certificate verification, endpoint restrictions, cancellation and no direct fallback. New analytics, remote artwork, browser/network SDKs or external services require an explicit architecture decision and leakage validation.

Do not log secrets, signed payloads, wallet addresses or Tor exit IPs. Use protocol error identifiers/sanitized messages. No cloud or cross-Mac recovery flow is part of this project.

### Preserve transaction intent

Use integer base units/BigUInt, validate chain identity, account, nonce/sequence, destination, amounts, fees and preview lifetime. Unknown RPC state is not zero balance, confirmed success, failure or cancellation. Persist hashes/attempts before broadcast and never add automatic duplicate payments.

Do not write cryptographic primitives. Use pinned upstream implementations and independent public vectors. Keep watch-only capabilities, unsupported paths and protocol-specific limits explicit.

### Localize interface text

English is default; Simplified Chinese is selectable live. Swift uses stable message keys and numbered arguments, with matching entries in both Localizable.strings files. Do not embed translated prose or change keys just to edit wording.

Keep amounts, addresses, hashes, protocol IDs and user names opaque. Preserve canonical legacy state values. Never force a root-view identity change to refresh language: current forms, credentials, approved previews and sessions must retain their state. See [I18N.md](Documentation/I18N.md).

### Maintain catalogs and artwork

Checked-in catalogs/icons are reviewed build inputs. Match network/contract/decimals rather than ticker names. Distinguish native issuance, bridges and legacy assets. Preserve official provenance and icon licenses.

Reference download scripts are maintenance tools, not normal build prerequisites. For example, build-market-catalog.py reads .build/price-reference/chains.json; deliberately updating it requires fetching the source data, reviewing identity changes and updating provenance. Never regenerate identities by symbol alone.

### Keep documentation portable and honest

Primary documentation is English. Use repository-relative links and checkout-relative commands; do not add personal filesystem paths. Preserve original upstream readmes/licenses/provenance.

README images are generated from explicit offline public fixtures, not the running personal wallet. Keep their warning/caption, audit every image and update [image provenance](Assets/Readme/README.md), its manifest and hash-bound audit exceptions. Arbitrary screenshots remain excluded. No private note/backup/seed screen belongs in product images.

## Review the exact publication contents

Stage only reviewed paths, then inspect and scan the actual index:

~~~bash
git add README.md CONTRIBUTING.md
git diff --cached --stat
git diff --cached
python3 Scripts/audit-source.py --source index --report .build/open-source-audit/index.json
python3 Scripts/check-documentation.py --source index
~~~

Replace the example paths with your change. The scanner reads exact Git blobs, including force-added ignored files, independently of worktree differences. CI checks the complete HEAD tree.

Configuration/SourceAuditAllowlist.json binds explicit rules to a complete file SHA256. It does not exempt Vendor or tests as directories. One changed byte invalidates an exception. Do not bulk-approve unknown findings: establish public provenance, remove accidental data or regenerate from a documented public fixture. A pass cannot prove absence of arbitrary encoded secrets or identify every personal address.

The local pre-commit hook repeats this scan. Do not bypass it to get a commit through.

Before publication, scan every historical tree with python3 Scripts/audit-source.py --source history. Shallow clones are rejected; CI fetches full history. --include-reflogs also covers locally retained commit versions. Public binary upload is separately controlled by [RELEASE_POLICY.md](Documentation/RELEASE_POLICY.md); a green build does not enable it.

## Submit a focused pull request

Include:

- The concrete problem and resulting user-visible behavior.
- Scope, protocol/version limits and any persisted-data implications.
- Checks run and their results, including skipped/uncompleted acceptance.
- For UI changes, reviewed public-fixture screenshots; for protocols, relevant official sources and independent vectors.

Use a title that describes the final change. Keep unrelated refactors/dependency updates separate. Never post raw scanner matches or sensitive reproduction material. Keep the root MIT license for original work and preserve third-party/GPL/LGPL notices. Public binary releases also need their corresponding-source/relinking materials; see [NOTICE.md](NOTICE.md).

The [source-check workflow](.github/workflows/source-audit.yml) runs on pushes/PRs. The [macOS packaging workflow](.github/workflows/macos-dmg.yml) builds explicit artifacts without publishing a Release. Do not claim remote CI passed until it has actually run.

## Clean up safely

~~~bash
python3 Scripts/clean-build-cache.py
python3 Scripts/clean-build-cache.py --apply --downloads
~~~

The first command previews; the second removes fixed project caches/dependencies/downloads. Stop builds first. Tracked source, Git, final packages and .tools auditing tools are retained; user Application Support/Keychain data is outside scope. Never commit .build, .tools, installed dependencies, runtime downloads, logs, wallet files or generated personal screenshots.
