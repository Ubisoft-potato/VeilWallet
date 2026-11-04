# Contributing

Veil Wallet is a native macOS development preview, not a production wallet or an independently audited product. Read [AGENTS.md](AGENTS.md), [the threat model](Documentation/SECURITY.md) and [the feature limits](Documentation/PRODUCT_SCOPE.md) before changing signing, persistence or networking.

## Build and check

Use macOS 14 or later and the tools listed in the README. Run the three developer runtime fetch scripts before packaging. Run SwiftPM operations sequentially:

```bash
./Scripts/swift.sh test
./Scripts/check-privacy.sh
python3 -m unittest discover -s Tests/Localization -p 'test_*.py'
python3 Tools/Localization/catalog.py --check
python3 Scripts/check-documentation.py
./Scripts/build-app.sh
```

Network requests from the running wallet must keep the Tor gate and fail-closed policy. The optional Anvil test uses an isolated local chain without a mainnet fork; fixtures are public, unfunded test material. Never test with an actual wallet or fund a published fixture. See [validation details](Documentation/VALIDATION.md).

The checked-in token/market catalogs and icons are build inputs. Reference download scripts are developer maintenance tools, not build prerequisites. `build-market-catalog.py` reads `.build/price-reference/chains.json`; when deliberately updating it, fetch `https://api.llama.fi/v2/chains` there, review identity changes and update the source provenance before committing. Never regenerate network identities based only on a matching ticker.

## Source publication guard

```bash
./Scripts/fetch-gitleaks.sh
python3 -m unittest discover -s Tests/SourceAudit -p 'test_*.py'
git add <reviewed-paths>
python3 Scripts/audit-source.py --report .build/open-source-audit/index.json
```

The scanner runs locally against all Git index blobs, including force-added ignored files. CI uses `--source head` to scan a complete checked-out commit. The Gitleaks download is pinned by version and platform SHA256. No scanner service receives repository contents. Reports contain paths, rules and file hashes, not matched values.

The installed scanner lives in ignored `.tools/gitleaks/` so cleaning build caches does not break the commit hook. `python3 Scripts/clean-build-cache.py` previews fixed project cache paths; add `--apply --downloads` to remove them and downloaded runtimes. It refuses paths containing tracked source. Do not clean while a build is running. Final artifacts in `build/` are retained.

DMG packaging and CI are described in [DMG_BUILD.md](Documentation/DMG_BUILD.md). Run `python3 -m unittest discover -s Tests/Packaging -p 'test_*.py'` when changing cleanup or distribution checks. Release compilation maps local checkout paths before packaging; the app-content check rejects local build paths, wallet files and private-key blocks in textual resources.

`Configuration/SourceAuditAllowlist.json` records reviewed public data with a complete file hash and explicit rules. It does not exempt `Vendor/` or tests as directories. Changing one byte invalidates that file's exceptions. Do not bulk-approve new findings: establish public provenance or regenerate from a documented public fixture first. A scan pass cannot prove the absence of arbitrary secrets or identify the owner of every public address.

To enable the local pre-commit check after installing Gitleaks:

```bash
git config --local core.hooksPath .githooks
```

Use a public Git author identity, such as your GitHub noreply email. Check the identity and staged diff locally before the first commit. The source audit does not redact Git author metadata, Git remotes or commit messages. Never put sensitive input into any of them.

Keep the MIT license for original contributions and preserve all existing third-party and GPL helper notices. Changes should describe the user-visible behavior, validation and remaining limits. Report security problems privately using [SECURITY.md](SECURITY.md).

English is the default UI/documentation language; Simplified Chinese remains selectable. Use stable L keys and numbered arguments, with matching entries in en.lproj and zh-Hans.lproj Localizable.strings. See Documentation/I18N.md. Keep addresses, amounts, user names, protocol IDs and canonical stored states unchanged. LK is for known catalog labels; LS is display-only compatibility for app-generated history. Language changes are observable and apply immediately; never force a root-view identity change to refresh text. See [UI.md](Documentation/UI.md).

Use relative repository links and checkout-relative commands in documentation, never personal home/checkout paths. Preserve third-party readmes, licenses and signed provenance. The documentation checker reports upstream content separately; do not rewrite upstream license text to silence it.
