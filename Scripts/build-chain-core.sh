#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/.build/ChainCore"
mkdir -p "$output" .build/go-cache .build/go-mod
fingerprint=$({
    ./Scripts/go.sh version
    ./Scripts/go.sh env GOOS GOARCH
    shasum -a 256 Configuration/Toolchains.json Scripts/go.sh
    shasum -a 256 Scripts/build-chain-core.sh
    find Native/ChainCore Vendor/OKXWalletSDK -type f \( -name '*.go' -o -name '*.txt' -o -name 'go.mod' -o -name 'go.sum' \) -print0 | sort -z | xargs -0 shasum -a 256
} | shasum -a 256 | awk '{print $1}')
if [ -f "$output/fingerprint" ] && [ "$(cat "$output/fingerprint")" = "$fingerprint" ] && [ -f "$output/libVeilChainCore.a" ]; then exit 0; fi
export GOCACHE="$PWD/.build/go-cache"
export GOMODCACHE="$PWD/.build/go-mod"
export CGO_ENABLED=1
export CGO_CFLAGS='-mmacosx-version-min=14.0'
export CGO_LDFLAGS='-mmacosx-version-min=14.0'
cd Native/ChainCore
# gofuzz selects geth's pure-Go secp256k1 backend, avoiding duplicate C symbols.
# Upstream purego implementations avoid assembly include paths that survive
# -trimpath; embedding absolute -asmflags would itself disclose the build path.
../../Scripts/go.sh build -tags=gofuzz,purego -mod=readonly -trimpath -buildmode=c-archive -ldflags='-s -w' -o "$output/libVeilChainCore.a" .
printf '%s' "$fingerprint" > "$output/fingerprint"
