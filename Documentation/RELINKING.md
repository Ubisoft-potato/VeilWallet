# Source delivery and local replacement

Release downloads include the installer, its exact committed application source, dependency sources, upstream source snapshots, the offline helper source, a source inventory, replacement-test evidence and SHA256SUMS. Keep these files together. Original component licenses apply; the root MIT license does not replace LGPL, GPL or other upstream notices.

The application source archive contains all original Swift/C/Go application code, the unmodified vendored SDK subset, manifests, build scripts, resource provenance, notices and the exact revision references. The dependency archive contains all three Swift dependency source trees, the external Go modules actually compiled into ChainCore and Go runtime sources. The helper archive contains its collected JavaScript/WASM sources, original licenses, circuit sources, fixed setup artifacts, lockfile, provenance and local modifications. Upstream archives contain pinned Tor sources and build recipes, lyrebird, Monero and Node sources. SOURCE-INVENTORY.json records component versions and source locations; MANIFEST.json hashes each delivered file.

## Build or relink a modified application

Use macOS 14 or later on Apple Silicon with Xcode 26.3 or a compatible newer Swift toolchain, Python 3, Go, Node/npm, GnuPG and ripgrep. BUILD-INFO.json records the actual release build environment. Apple's platform SDKs and tools are obtained from Apple; they are not included in these source archives.

Extract the application source and run commands from its root:

~~~bash
./Scripts/fetch-tor.sh
./Scripts/fetch-monero.sh
./Scripts/fetch-privacy-runtime.sh
./Scripts/swift.sh test
./Scripts/build-app.sh
~~~

Modify the supplied LGPL library source or application source, then rebuild. The local SDK replacement is selected by the replace directives in Native/ChainCore/go.mod. To replace upstream go-ethereum, extract its supplied source and add a local module replacement pointing to that directory in Native/ChainCore/go.mod. Swift dependencies can likewise use local package dependencies for the delivered source. Retain their upstream notices. Clear the native build fingerprint after changing dependency sources:

~~~bash
rm -f .build/ChainCore/fingerprint
./Scripts/build-app.sh
~~~

This compiles a new C archive and relinks the Swift executable. The build script signs the modified application ad hoc; no publisher identity, Apple Developer certificate, notarization, remote attestation or online approval is needed. You may modify and relink LGPL components and reverse engineer the combined work to debug those changes. Do not treat an ad-hoc signature as a publisher identity or an independent security review.

The supplied sources can replace developer downloads. Scripts/swift.sh and Scripts/go.sh use pinned developer dependencies; they do not impose a restriction on local source modifications. The installed wallet never downloads executable code. To replace separate Tor, Monero, Node or helper processes, build the corresponding upstream source using its supplied instructions, use the existing local protocol, then regenerate resource inventories and ad-hoc signatures. Canonical privacy-pool setup artifacts must remain compatible with the selected deployed pool; generating a different setup is a protocol change.

## Release replacement test

The automated release test adds a temporary LGPL test file to the compiled upstream go-ethereum common and RLP packages in an independent local module replacement. Each package's initializer emits a distinct public marker. It rebuilds the native archive, relinks the actual Swift application and executes a small C ABI empty-input fixture against the replacement archive. Both markers and the expected error response must be observed. It does not generate/import wallet keys, open a vault, start the wallet UI or contact a network service.

The temporary module replacement and test files are removed before the unmodified release application is built. RELINK-VERIFICATION.json records the exact committed tree, modified application/archive hashes and successful observations; the temporary modified application is not distributed. This verifies source replacement and relinking mechanically. It is not a legal opinion, security audit or guarantee of reproducible bytes for upstream binaries.

~~~bash
python3 Scripts/release-materials.py fetch
python3 Scripts/release-materials.py relink
./Scripts/build-dmg.sh
python3 Scripts/release-materials.py prepare
python3 Scripts/check-release-policy.py --require-binary --stage-materials
python3 Scripts/release-materials.py upload
~~~

The preparation commands require a clean committed source tree. The final gate rejects a stale build, mismatched source tree, missing replacement evidence, missing source deliveries or changed artifact hashes. Upload staging copies only the explicit verified files. Source-only checks validate policy configuration without authorizing any binary upload.
