# macOS DMG build and installation

Apple Silicon, macOS 14+. The DMG contains Veil Wallet.app, an Applications shortcut and Install.txt. Drag the App into Applications and eject. The shortcut targets the standard system Applications directory, not a checkout path.

## Local build

~~~bash
./Scripts/fetch-tor.sh
./Scripts/fetch-monero.sh
./Scripts/fetch-privacy-runtime.sh
./Scripts/swift.sh test
./Scripts/build-dmg.sh
~~~

Release packaging checks resources, architecture and nested signatures; hdiutil creates the compressed image. It mounts read-only, compares every App file hash, permission and symlink, verifies the Applications shortcut and unmounts. It never launches a wallet or reads user wallet data. --skip-build reuses the existing App with all checks.

Outputs in build/:

- VeilWallet-<version>-macOS-arm64.dmg: installer.
- VeilWallet-<version>-macOS-arm64.zip: same App.
- BUILD-INFO.json: architecture, toolchain, source tree/commit, runtime versions and signing mode, without builder username/certificate identity.
- SHA256SUMS: artifacts/metadata/source snapshot checksums. Run shasum -a 256 -c SHA256SUMS inside that directory.

Local delivery may remove the ZIP after DMG verification; remove its checksum row too.

Release maps checkout paths, uses upstream portable Go implementations and strips local symbols before signing. Verification rejects personal build paths, wallet files and text PEM private keys. Official Node/proof artifacts can retain public upstream paths; preserve their pinned provenance rather than rewrite them.

## GitHub Actions

[macos-dmg.yml](../.github/workflows/macos-dmg.yml) builds when a new `v*` tag is pushed. The tag must match the version in [Info.plist](../Configuration/Info.plist), for example `v0.10.6`.

Pinned environment: ARM64 macos-15, Xcode 26.3, Go 1.26.10. See [runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md). Unexpected architecture/toolchain stops the build.

Steps: full-history and HEAD secret scans, exact-HEAD documentation checks, scanner tests, verified runtime downloads, default Swift tests, runtime dependency-advisory checks and App/DMG validation. Read-only permissions, no persisted checkout credentials, signing secrets or shared build caches. No cache/workspace upload. Actions use full commit SHAs.

Binary artifact upload is disabled by default. [BinaryDistribution.json](../Configuration/BinaryDistribution.json) enables it only with a reviewed exact-tree corresponding-source/relink materials manifest. The workflow can still validate builds while publishing source only. See [RELEASE_POLICY.md](RELEASE_POLICY.md).

Default CI does not install Anvil or set VEIL_VERIFY_NODE=1; optional checks skip. Prepared offline proof and other default checks run. This is not a funded-chain test.

When distribution is enabled, artifacts last 14 days. A source tarball from HEAD excludes history/local settings/caches. It does not replace all corresponding-source/relinking obligations; see [NOTICE](../NOTICE.md) and [licenses](THIRD_PARTY.md). No GitHub Release is published.

Default signing is ad-hoc, without notarization. Verify source/checksums before following macOS Privacy & Security prompts. Do not disable Gatekeeper. Developer ID/notarization need a separately configured authorized Apple identity.

## Cleanup

~~~bash
python3 Scripts/clean-build-cache.py
python3 Scripts/clean-build-cache.py --apply --downloads
~~~

First previews; second removes fixed project cache/dependency/runtime/download locations. Stop builds first. It refuses tracked files and never follows external symlinks. Git, source, public verification keys, final packages and audit tools remain. Application Support/Keychain user data is outside its scope.
