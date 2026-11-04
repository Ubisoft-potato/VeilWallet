#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = --help ]; then
    echo 'Usage: ./Scripts/build-app.sh [release|debug]'
    echo 'Builds a signed .app, a ZIP archive and SHA256SUMS in build/.'
    exit 0
fi
[ "$(uname -s)" = Darwin ] || { echo 'Packaging requires macOS' >&2; exit 1; }
[ "$#" -le 1 ] || { echo 'Use release or debug' >&2; exit 1; }
configuration=${1:-release}
[ "$configuration" = release ] || [ "$configuration" = debug ] || { echo 'Use release or debug' >&2; exit 1; }
for command in swift go python3 codesign ditto plutil lipo shasum strip; do
    command -v "$command" >/dev/null || { echo "Missing build dependency: $command" >&2; exit 1; }
done
[ -x Vendor/Tor/tor/tor ] || { echo 'Run Scripts/fetch-tor.sh first' >&2; exit 1; }
[ -x Vendor/Monero/monero-wallet-rpc ] || { echo 'Run Scripts/fetch-monero.sh first' >&2; exit 1; }
[ -x Vendor/PrivacyRuntime/node ] || { echo 'Run Scripts/fetch-privacy-runtime.sh first' >&2; exit 1; }
python3 Scripts/privacy-manifest.py Vendor/PrivacyRuntime --verify
python3 Scripts/check-dependencies.py --offline-runtime
./Scripts/check-privacy.sh
build_options=(build -c "$configuration")
if [ "$configuration" = release ]; then
    # Avoid embedding the developer's home / checkout path in distributed code.
    build_options+=(-Xswiftc -file-prefix-map -Xswiftc "$PWD=/VeilWallet"
                    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/VeilWallet"
                    -Xcc "-ffile-prefix-map=$PWD=/VeilWallet"
                    -Xcc "-fdebug-prefix-map=$PWD=/VeilWallet")
fi
./Scripts/swift.sh "${build_options[@]}"
python3 Scripts/collect-go-licenses.py
bin=$(./Scripts/swift.sh build -c "$configuration" --show-bin-path)
mkdir -p "$PWD/build"
final_app="$PWD/build/Veil Wallet.app"
staging=$(mktemp -d "$PWD/build/.package.XXXXXX")
backup_app="$staging/previous.app"
cleanup() {
    package_exit_code=$?
    trap - EXIT
    if [ -d "$backup_app" ] && [ ! -e "$final_app" ]; then mv "$backup_app" "$final_app"; fi
    rm -rf "$staging"
    exit "$package_exit_code"
}
trap cleanup EXIT
app="$staging/Veil Wallet.app"
helper="$app/Contents/Helpers/TorRuntime.bundle"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$helper/Contents/MacOS" "$helper/Contents/Resources"
cp "$bin/VeilWallet" "$app/Contents/MacOS/VeilWallet"
if [ "$configuration" = release ]; then
    # Linker debug-map / local symbols can retain object paths even after prefix
    # mapping. Strip the staged executable before signing; keep build symbols local.
    strip -S -x "$app/Contents/MacOS/VeilWallet"
fi
cp Configuration/Info.plist "$app/Contents/Info.plist"
cp Configuration/PrivacyInfo.xcprivacy "$app/Contents/Resources/PrivacyInfo.xcprivacy"
for resource in "$bin"/*.bundle; do
    case "$(basename "$resource")" in *Tests.bundle) continue ;; esac
    [ ! -d "$resource" ] || ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
cp Configuration/TorRuntime-Info.plist "$helper/Contents/Info.plist"
cp Vendor/Tor/tor/tor "$helper/Contents/MacOS/tor"
cp Vendor/Tor/tor/libevent-2.1.7.dylib "$helper/Contents/MacOS/libevent-2.1.7.dylib"
cp Vendor/Tor/tor/pluggable_transports/lyrebird "$helper/Contents/MacOS/lyrebird"
ditto Vendor/Tor/data "$helper/Contents/Resources/data"
ditto Vendor/Tor/docs "$helper/Contents/Resources/docs"
cp Vendor/tor-browser-release-key.asc "$app/Contents/Resources/tor-release-key.asc"
monero_helper="$app/Contents/Helpers/MoneroRuntime.bundle"
mkdir -p "$monero_helper/Contents/MacOS" "$monero_helper/Contents/Resources"
cp Vendor/Monero/monero-wallet-rpc "$monero_helper/Contents/MacOS/monero-wallet-rpc"
cp Configuration/MoneroRuntime-Info.plist "$monero_helper/Contents/Info.plist"
cp Vendor/Monero/hashes.txt Vendor/Monero/VERSION Vendor/monero-binaryfate.asc "$monero_helper/Contents/Resources/"
for notice in LICENSE README.md ANONYMITY_NETWORKS.md; do [ ! -f "Vendor/Monero/$notice" ] || cp "Vendor/Monero/$notice" "$monero_helper/Contents/Resources/"; done
privacy_helper="$app/Contents/Helpers/PrivacyRuntime.bundle"
mkdir -p "$privacy_helper/Contents/MacOS" "$privacy_helper/Contents/Resources"
cp Configuration/PrivacyRuntime-Info.plist "$privacy_helper/Contents/Info.plist"
cp Vendor/PrivacyRuntime/node "$privacy_helper/Contents/MacOS/node"
for entry in Vendor/PrivacyRuntime/*; do
    case "$(basename "$entry")" in node|manifest.json) continue ;; esac
    ditto "$entry" "$privacy_helper/Contents/Resources/$(basename "$entry")"
done
mkdir -p "$privacy_helper/Contents/Resources/source/build"
cp Scripts/collect-privacy-runtime.cjs Scripts/prepare-privacy-deps.cjs Scripts/fetch-privacy-runtime.sh Scripts/privacy-manifest.py Scripts/build-app.sh "$privacy_helper/Contents/Resources/source/build/"
cp Tools/PrivacyProof/package.json Tools/PrivacyProof/package-lock.json "$privacy_helper/Contents/Resources/source/"
cp Tools/PrivacyProof/snarkjs-prover-entry.cjs Configuration/PrivacyDependencyPolicy.json "$privacy_helper/Contents/Resources/source/"
ditto Configuration/Licenses "$app/Contents/Resources/Licenses"
cp Documentation/THIRD_PARTY.md "$app/Contents/Resources/THIRD_PARTY.md"
cp LICENSE "$app/Contents/Resources/Licenses/VeilWallet-MIT.txt"
cp NOTICE.md "$app/Contents/Resources/NOTICE.md"
cp Configuration/TrustWallet-Assets-LICENSE.txt Configuration/Cryptocurrency-Icons-CC0.txt Configuration/ErikThiart-Icons-LICENSE.txt "$app/Contents/Resources/Licenses/"
if [ -f Configuration/AppIcon.icns ]; then cp Configuration/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
architecture=$(uname -m)
for executable in "$app/Contents/MacOS/VeilWallet" "$helper/Contents/MacOS/tor" "$helper/Contents/MacOS/lyrebird" "$helper/Contents/MacOS/libevent-2.1.7.dylib" "$monero_helper/Contents/MacOS/monero-wallet-rpc" "$privacy_helper/Contents/MacOS/node"; do
    lipo -verify_arch "$architecture" "$executable" || { echo "Architecture mismatch: $executable" >&2; exit 1; }
done
python3 - "$app" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundlePackageType'] == 'APPL'
assert (app / 'Contents/MacOS' / info['CFBundleExecutable']).is_file()
core = app / 'Contents/Resources/VeilWallet_WalletCore.bundle/Contents/Resources'
for name in ['bip39-english.txt', 'evm-networks.json', 'dex-venues.json', 'token-presets.json', 'market-prices.json', 'asset-usdt.png', 'asset-usdc.png', 'asset-trx.png', 'asset-usdd.png', 'asset-sun.png', 'asset-jst.png', 'cacert.pem']:
    assert (core / name).stat().st_size > 0, f'Missing runtime resource: {name}'
assert len((core / 'bip39-english.txt').read_text().split()) == 2048
networks = json.loads((core / 'evm-networks.json').read_text())
assert networks and len({row['id'] for row in networks}) == len(networks)
venues = json.loads((core / 'dex-venues.json').read_text())
assert len(venues) >= 73 and len({row['id'] for row in venues}) == len(venues)
assert all(row['source'].startswith('https://') for row in venues)
markets = json.loads((core / 'market-prices.json').read_text())['networks']
assert len(markets) == 119 and len({row['chainID'] for row in markets}) == len(markets)
helper = app / 'Contents/Helpers/TorRuntime.bundle/Contents'
for name in ['geoip', 'geoip6']:
    assert (helper / 'Resources/data' / name).stat().st_size > 0
assert (app / 'Contents/Resources/PrivacyInfo.xcprivacy').is_file()
assert (app / 'Contents/Resources/Licenses').is_dir()
monero = app / 'Contents/Helpers/MoneroRuntime.bundle/Contents'
assert (monero / 'MacOS/monero-wallet-rpc').stat().st_size > 0
for name in ['VERSION', 'hashes.txt', 'monero-binaryfate.asc', 'LICENSE']:
    assert (monero / 'Resources' / name).stat().st_size > 0, f'Missing Monero provenance: {name}'
assert (monero / 'Resources/VERSION').read_text().strip() == '0.18.5.4'
assert not list(app.rglob('*Tests.bundle')), 'Tests must not ship in the app'
print(f'Runtime resources verified: {len(networks)} EVM mainnets')
PY
identity=${VEIL_SIGNING_IDENTITY:--}
# Ad-hoc nested executables cannot satisfy Library Validation for their non-platform dylibs.
# Real Developer ID builds sign every helper component with the same Team ID.
sign_helper() {
    if [ "$identity" = - ]; then codesign --force --sign "$identity" "$1"
    else codesign --force --sign "$identity" --options runtime "$1"
    fi
}
find "$helper/Contents/MacOS" -type f -print0 | while IFS= read -r -d '' file; do
    if /usr/bin/file "$file" | /usr/bin/grep -q 'Mach-O'; then sign_helper "$file"; fi
done
sign_helper "$helper"
sign_helper "$monero_helper/Contents/MacOS/monero-wallet-rpc"
sign_helper "$monero_helper"
codesign --force --sign "$identity" --options runtime --entitlements Configuration/PrivacyRuntime.entitlements "$privacy_helper"
# Keep the inventory outside Node's own signed resource envelope; then sealing
# the outer App binds both without a circular executable/manifest dependency.
python3 Scripts/privacy-manifest.py "$privacy_helper"
python3 Scripts/privacy-manifest.py "$privacy_helper" --verify
codesign --force --sign "$identity" --options runtime "$app"
codesign --verify --deep --strict "$app"
if [ "$configuration" = release ]; then python3 Scripts/verify-app.py "$app"; fi
version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
archive_name="VeilWallet-$version-macOS-$architecture.zip"
if [ "$configuration" = debug ]; then archive_name="VeilWallet-$version-debug-macOS-$architecture.zip"; fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/$archive_name"
(
    cd "$staging"
    shasum -a 256 'Veil Wallet.app/Contents/MacOS/VeilWallet' "$archive_name" > SHA256SUMS
)
# Publish only after resources, signatures and the archive are complete.
if [ -e "$final_app" ]; then mv "$final_app" "$backup_app"; fi
mv "$app" "$final_app"
mv "$staging/$archive_name" "$PWD/build/$archive_name"
mv "$staging/SHA256SUMS" "$PWD/build/SHA256SUMS"
echo "Built: $final_app"
echo "Archive: $PWD/build/$archive_name"
echo "Checksums: $PWD/build/SHA256SUMS"
echo "Launch: open '$final_app'"
