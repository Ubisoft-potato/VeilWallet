# Source previews and binary distribution

The repository can publish source previews while CI builds and verifies installers. **Public binary artifact upload is disabled by default.** Local App/DMG builds remain available.

[BinaryDistribution.json](../Configuration/BinaryDistribution.json) is the reviewed policy. The workflow runs [check-release-policy.py](../Scripts/check-release-policy.py) before upload and uses its enabled output. An unchecked manual-dispatch flag or repository variable cannot bypass it. Invalid policies/materials fail closed.

## Required delivery before enabling binary upload

Provide a reviewed materials manifest for the exact committed source tree. It must record:

- Schema version 1 and sourceTree matching the release HEAD tree.
- BUILD-INFO.json from the exact clean committed tree; dirty or mismatched binaries are rejected.
- reviewedForBinaryDistribution and relinkVerified set to true after actual review/testing.
- The complete component inventory: application, swift-dependencies, go-dependencies, go-runtime, tor, monero, node and privacy-helper.
- A nonempty artifacts list with project-relative path and SHA256 for each corresponding-source/relink delivery. Every file must exist and match its hash; escaping paths and symlinks are rejected.

The materials cover exact source revisions, local modifications, licenses and build/relink instructions for the distributed versions. Repository-only source archives and copied license texts do not automatically satisfy every third-party requirement. Test rebuilding with the required modified library/source delivery and preserve the result as review evidence. See [NOTICE.md](../NOTICE.md) and [third-party boundaries](THIRD_PARTY.md).

Once these materials have been reviewed, point materialsManifest to that manifest and enable the policy in a reviewed commit. CI checks its exact tree and artifact hashes before any binary upload. The checker is a mechanical delivery gate, not an automated legal certification; do not assert review fields without the underlying work. A different source tree or changed material invalidates the gate.

Generate the exact-tree manifest under ignored build/ after preparing the deliveries, using a reviewed CI preparation step before the gate. Do not commit a manifest containing its own Git tree hash; that would be self-referential. The source-preview workflow intentionally has no unreviewed producer that asserts legal/relink approval automatically.

When enabled, the gate stages only the hash-verified material files and MANIFEST.json into build/release-materials/. That explicit directory is uploaded alongside the installer, source snapshot and checksums. Filename collisions and files changed during staging are rejected; unrelated workspace/cache files are not copied.

## Local and CI behavior

~~~bash
python3 Scripts/check-release-policy.py
python3 Scripts/check-release-policy.py --require-binary
~~~

The first command reports the current posture. The second returns failure while public binary distribution is disabled or materials are incomplete. Source-preview CI can still run tests, package a DMG and mount-verify it without uploading the binary. The policy does not publish a GitHub Release or require private signing credentials.

Source checks use exact HEAD/index blobs and full Git history. Commit all reviewed documentation, then run:

~~~bash
python3 Scripts/check-documentation.py --source head
python3 Scripts/audit-source.py --source history
~~~

Keep the development-preview label until the separate security, live-funds and notarization acceptance work is complete. Enabling artifact delivery does not establish that the wallet is independently audited or production-ready.
