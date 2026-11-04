# Source-publication review

Scope: the proposed Git source tree, configuration, documentation, resources, tests and vendored source. No real wallet directory/Keychain was inspected or uploaded. No GitHub repository, commit or push was created during preparation. This is a publication-content review, not a security audit of wallet behavior.

## Review policy

Public test keys/mnemonics remain intentionally present; never fund those fixtures. Tor/Monero public verification keys and the Node public release keyring are build-verification material, not wallet or publisher private keys.

A prior review matched all 1,061 SDK files against the pinned upstream revision and 92 icons against provenance SHA256 values. Generic scanner candidates were reviewed as public vectors, protocol constants/contracts or public signing fingerprints. Supplemental wallet rules cover mnemonic fragments, unexplained 32-byte hex, encoded keys, notes, credential URLs, personal paths, risky filenames and binary resources.

Exceptions in [SourceAuditAllowlist.json](../Configuration/SourceAuditAllowlist.json) bind explicit rules to whole-file SHA256. There are no Vendor/test directory exemptions. Any file change invalidates its exception. Personal paths/private PEM/risky paths cannot be exempted. Changed public-vector/hash files must be re-reviewed; do not bulk-approve unknown findings.

Builds, installed dependencies, runtime downloads, logs, local configuration, wallet files, signing material and generated screenshots are ignored. Screenshots and ZIPs are not part of the source tree. Original upstream notices/provenance are retained.

## Repeatable local checks

~~~bash
./Scripts/fetch-gitleaks.sh
python3 -m unittest discover -s Tests/SourceAudit -p 'test_*.py'
python3 -m unittest discover -s Tests/Packaging -p 'test_*.py'
python3 -m unittest discover -s Tests/Localization -p 'test_*.py'
python3 Tools/Localization/catalog.py --check
python3 Scripts/check-documentation.py
python3 Scripts/audit-source.py --source index --report .build/open-source-audit/index.json
./Scripts/check-privacy.sh
~~~

Gitleaks 8.30.1 is pinned to [official release](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1) platform checksums. It scans all actual Git index blobs in local temporary storage, including force-added ignored files, independently of worktree differences and repository-controlled ignore rules. CI scans full HEAD. No scanning service receives contents. Reports contain file/rule/line/hash metadata, not matched values; raw temporary reports are removed.

12 scanner tests cover mnemonic/key encodings, credential URLs, personal paths, binary resources, forced ignored files, whole-file exception invalidation, symlink rejection and actual staged-blob reading. Seven packaging/cleanup tests cover prohibited payloads/paths and safe cleanup. Localization/documentation checks add coverage/placeholder and portable-link/path regression.

A prior wider filename inventory covered 61,400 project/cache files. Upstream examples in caches were distinguished from user secrets. That inventory is historical, not a repeated claim for every later build, and did not inspect system Keychain or actual wallet data.

## Documentation and language

First-party README/security/product/build/contribution documentation is English. Repository links/commands use relative paths or checkout-relative variables. The path checker reviews tracked and non-ignored Markdown/text documentation and JSON reports, distinguishes URLs/derivation paths from filesystem paths, checks local links and reports preserved upstream content separately. No personal checkout path is needed in documentation.

Third-party source/readmes/licenses and signed provenance are preserved verbatim. Non-English upstream text or official archive path syntax is not silently rewritten. Historical JSON descriptions may be translated for readability; measured outcomes remain historical, not rerun results.

## Packages and caches

Release builds map local checkout paths, use upstream portable Go implementations and strip symbols before signing. App verification checks prohibited wallet filenames/private-key blocks and local build paths. Official runtime/proof artifacts retain public upstream build paths to preserve provenance.

DMGs are actually mounted read-only and compared to the verified App, including hashes, permissions, symlinks, architecture/signatures and Applications shortcut. Source tarballs are checked against the exact staged tree. Package metadata/checksums live in the ignored build directory. See [DMG_BUILD.md](DMG_BUILD.md).

Cleanup removes fixed project cache/dependency/runtime/download locations only, retaining source/Git/final artifacts/public verification keys/local audit tools. It refuses tracked paths and external symlinks. User Application Support/Keychain data is outside scope. Run after builds finish; temporary raw logs/reports are removed too.

## Publication status and limits

The local branch is main, with no initial commit/public author identity/remote configured. There is no existing commit history to rewrite. Before first commit, choose a public name/email and inspect staged content. Scanning does not redact author metadata, remotes or messages; future HEAD checks do not replace history scans.

Original work uses MIT; upstream licenses remain, including GPL/LGPL corresponding-source/relinking requirements. Source readiness does not clear binary redistribution. See [NOTICE](../NOTICE.md) and [THIRD_PARTY.md](THIRD_PARTY.md).

After creating a repository, enable [private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository) and update [SECURITY.md](../SECURITY.md). No remote CI run or push is claimed. Pattern scanning cannot prove absence of arbitrary encoded secrets or identify every personal address.
