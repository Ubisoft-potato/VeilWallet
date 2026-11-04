# License scope

The root [MIT license](LICENSE) covers original Veil Wallet code and documentation unless a file or directory carries a different notice. It does not replace third-party licenses or grant rights to third-party trademarks.

- `Vendor/OKXWalletSDK/` is an unmodified subset of the upstream revision recorded in `UPSTREAM_COMMIT`. Preserve its root and nested licenses, including LGPL components.
- `Tools/PrivacyProof/`, `Scripts/collect-privacy-runtime.cjs`, `Scripts/prepare-privacy-deps.cjs`, `Scripts/fetch-privacy-runtime.sh` and `Scripts/privacy-manifest.py` are GPL-3.0-or-later. Their license text is in `Tools/PrivacyProof/LICENSE`. The packaged offline helper retains its own licenses and corresponding-source requirements. `Vendor/PrivacyRuntime/source/` includes upstream circuit source and notices. MIT does not override these notices.
- `Configuration/Licenses/` contains dependency notices. `Documentation/THIRD_PARTY.md` records versions, source locations, static-linking considerations and separate runtime components.
- Asset artwork retains the licenses in `Configuration/` and the provenance in `Documentation/ASSET_ARTWORK.json`. The bundled CA certificate store retains its upstream MPL-2.0 notice.
- Public Tor and Monero signing keys and the Node release keyring are verification material, not wallet keys or publisher signing secrets.

The Git repository distributes source and reviewed public resources. Downloaded executables, installed dependencies, proving artifacts and packaged applications are excluded. Publishing a binary release is a separate step: include the exact corresponding sources, license notices and rebuild/relink materials required by the included licenses. A successful secret scan does not establish binary redistribution compliance or a security audit of the wallet.
