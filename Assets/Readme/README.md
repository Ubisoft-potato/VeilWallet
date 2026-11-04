# README image provenance

These are version 0.10.1 product-documentation assets, not captures of a personal wallet.

- hero.svg is original vector artwork based on the shield geometry in [make-icon.swift](../../Scripts/make-icon.swift). No external fonts, scripts or images are loaded.
- overview.png uses the native RootView with an explicit public-fixture banner and illustrative local balances/prices.
- swap.png and networks.png show existing native forms/selectors in offline preview mode.
- transactions.png uses repeated synthetic hashes and public-fixture accounts.
- manifest.json records every shipped image's SHA256, dimensions and source scene. Each PNG also has an individual whole-file binary-review exception in the source-publication guard.

The PNG exporter converts native pixels to standard sRGB and retains image/color chunks only. EXIF and text chunks are removed. All four images were visually reviewed and checked for private-key blocks, encoded key formats, private notes, personal paths and email addresses with local OCR. Automated checks complement the public-fixture provenance; they cannot prove arbitrary secrets are absent from any image.

## Reproduce

From the repository root, after preparing the developer dependencies:

~~~bash
mkdir -p .build/readme/previews
./Scripts/swift.sh build --product VeilWallet
.build/out/Products/Debug/VeilWallet --render-preview .build/readme/previews/assets.png -VeilWallet.interfaceLanguage en
~~~

Use only these explicit renderer outputs:

| Shipped file | Generated source |
|---|---|
| overview.png | readme-overview.png |
| swap.png | dex-preview.png |
| networks.png | network-search-preview.png |
| transactions.png | transactions-preview.png |

The existing DEBUG renderer uses AppModel(previewMode: true), a published BIP39 standard vector and deterministic illustrative values. It does not open a user vault, read local transaction history, start Tor or broadcast. Preview entry points do not ship in Release.

Inspect every selected image before copying it here. No seed/backup/private-note view is included. Keep the explicit fixture label/caption, check PNG metadata and update the manifest and hash-bound audit entries after regeneration. Do not replace these files with screenshots of an actual wallet.

Source publication checks deliberately continue to reject PNG screenshots under Documentation. These specific reviewed product images live in this separate directory; no directory-wide binary exception is granted. Generated previews/caches remain ignored.

Original artwork/UI documentation uses the root [MIT license](../../LICENSE); embedded third-party asset logos retain their [artwork licenses and provenance](../../Documentation/ASSET_ARTWORK.json).
