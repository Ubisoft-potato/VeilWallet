#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Developer bootstrap only. The installed app never downloads executable code.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -m)" = arm64 ] || { echo 'Privacy runtime currently supports macOS arm64 only' >&2; exit 1; }
for command in curl python3 npm gpgv; do command -v "$command" >/dev/null || { echo "Missing: $command" >&2; exit 1; }; done
version=24.22.2
archive="node-v$version-darwin-arm64.tar.gz"
cache="$PWD/.build/privacy-download"
mkdir -p "$cache/gnupg" Vendor/PrivacyRuntime/artifacts
chmod 700 "$cache/gnupg"
fetch() { if [ ! -f "$2" ]; then curl --fail --location --proto '=https' --tlsv1.2 "$1" -o "$2.partial"; mv "$2.partial" "$2"; fi; }
fetch "https://nodejs.org/dist/v$version/$archive" "$cache/$archive"
fetch "https://nodejs.org/dist/v$version/SHASUMS256.txt.asc" "$cache/SHASUMS256.txt.asc"
printf '%s  %s\n' 610b8d249da3d5733f5a128def2dd0294dbbf5b5713e6ca2529db8db419dee00 Vendor/PrivacyRuntime/provenance/node-release-keyring.kbx | shasum -a 256 -c -
gpgv --homedir "$cache/gnupg" --keyring "$PWD/Vendor/PrivacyRuntime/provenance/node-release-keyring.kbx" --output "$cache/SHASUMS256.verified" "$cache/SHASUMS256.txt.asc"
printf '%s  %s\n' aa9549349e47dffaa42dcf95d6e06ade8c4bdafc980979883b88767670df385a "$cache/$archive" | shasum -a 256 -c -
awk -v name="$archive" '$1=="aa9549349e47dffaa42dcf95d6e06ade8c4bdafc980979883b88767670df385a" && $2==name {found=1} END {exit !found}' "$cache/SHASUMS256.verified"
tar -xOzf "$cache/$archive" "node-v$version-darwin-arm64/bin/node" > Vendor/PrivacyRuntime/node
tar -xOzf "$cache/$archive" "node-v$version-darwin-arm64/LICENSE" > Vendor/PrivacyRuntime/NODE-LICENSE
chmod 755 Vendor/PrivacyRuntime/node
for name in tornado.json tornadoProvingKey.bin; do
    fetch "https://raw.githubusercontent.com/tornadocash/tornado-cli/378ddf8b8b92a4924037d7b64a94dbfd5a7dd6e8/build/circuits/$name" "Vendor/PrivacyRuntime/artifacts/$name"
done
python3 - <<'PY'
import hashlib,json
from pathlib import Path
root=Path('Vendor/PrivacyRuntime'); manifest=json.loads((root/'provenance/ORIGINS.json').read_text())
for name, expected in manifest['tornado']['artifacts'].items():
    data=(root/'artifacts'/name).read_bytes()
    assert hashlib.sha256(data).hexdigest()==expected['sha256'], 'Circuit SHA256 mismatch'
    assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==expected['gitBlobSHA1'], 'Circuit Git blob mismatch'
PY
(cd Tools/PrivacyProof && npm ci --ignore-scripts --no-audit --no-fund)
Vendor/PrivacyRuntime/node --no-addons Scripts/prepare-privacy-deps.cjs
Vendor/PrivacyRuntime/node --no-addons Scripts/collect-privacy-runtime.cjs
python3 Scripts/privacy-manifest.py Vendor/PrivacyRuntime
python3 Scripts/privacy-manifest.py Vendor/PrivacyRuntime --verify
echo 'Pinned offline privacy runtime prepared. No external prover is used by the app.'
