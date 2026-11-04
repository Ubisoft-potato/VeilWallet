# Native interface

## Language

English is default; select English or Simplified Chinese on the offline unlock screen or Settings. Changes apply immediately, including already open views, without resetting form state. The non-sensitive preference is app-local and never synced; vault schemas, route identities, canonical legacy status strings and signing data do not change.

Application messages use stable keys and numbered arguments in standard en.lproj/zh-Hans.lproj Localizable.strings resources. Swift contains no translated message literals. See [I18N.md](I18N.md). Amounts, addresses, hashes and other interpolated values remain opaque and unchanged. Catalog validation checks complete production-literal coverage and placeholder parity. App-owned catalog labels are translated; user wallet/network names remain their original values. App-generated cached descriptions in either language are translated only for display when recognized; unknown historical messages retain their original wording.

Dates use the selected UI locale. Token parsing, units, contract parameters and protocol serialization retain their existing rules.

## Persistent hover feedback

A persistent ButtonSurface view owns hover state for sidebar/network/disclosure rows, ordinary/primary buttons and icons. Repeated enter signals do not restart animation; highlight persists during hover and parent redraw. Enter: 180ms, exit: 240ms. Only background/border animate, respecting Reduce Motion, without changing hit areas. Primary buttons retain their accent; other surfaces use fixed dark purple/gray. No white hover/pressed fill.

~~~bash
.build/out/Products/Debug/VeilWallet --verify-hover .build/veil-hover-check.json
~~~

Seven control classes check visible highlight, hold/redraw persistence, exit reset, disabled behavior and rapid enter/exit colors. DEBUG phase signals call the same state handler, then sample real rendering. Signals do not replay on resubscription. This **does not verify operating-system pointer tracking** in an inactive/offscreen window. [Historical results](UI_HOVER_0.9.3.json) explicitly record that limit. Release excludes probe subscriptions/entry points.

## Click targets and layout

Seven sidebar rows have full 48pt targets, whitespace included, with Command-1…7 and separate selected/hover/press/focus feedback. Background querying does not block navigation.

Every disclosure has a 52pt full-row header with state/chevron. Inputs, copy actions and internal controls remain independent; collapsing retains form state. Coverage includes hashes, approved parameters, import paths, both fee editors, note import/failure handling and advanced network settings.

Icons are at least 36×36pt, ordinary actions 40pt high, primary actions 44pt. Asset/transaction action groups wrap. Hash attempts use separate cards with full wrapping/copy controls. Approved parameters load from encrypted local archives only when requested and close when the current transaction changes.

~~~bash
./Scripts/swift.sh build --product VeilWallet
.build/out/Products/Debug/VeilWallet --verify-ui .build/veil-ui-check.json
~~~

Native mouse events are sent directly to our own off-desktop test window: sidebar whitespace, disclosure/input interactions, retained state, disabled controls and six independently clickable actions at 360pt width. No system event injection, accessibility permission, vault access or networking. Geometry observers do not hit-test and return the original view in Release. See [historical click results](UI_INTERACTION_0.9.3.json).

Preview rendering uses public disposable vectors and clearly labeled illustrative balances/prices; it never substitutes test data in production. Generated previews stay in ignored build directories. Explicitly reviewed public-fixture [README images](../Assets/Readme/README.md) have provenance and individual hash-bound audit exceptions; personal captures remain excluded.
