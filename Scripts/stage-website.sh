#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
    echo 'Usage: bash Scripts/stage-website.sh <empty-output-directory>' >&2
    exit 1
fi

site=$1
mkdir -p "$site"
if [ -n "$(ls -A "$site")" ]; then
    echo 'Choose an empty output directory for the website.' >&2
    exit 1
fi

install -d "$site/screenshots" "$site/networks"
install -m 644 Website/{index.html,styles.css,mark.svg} "$site/"
install -m 644 Assets/Readme/{overview,networks,swap,transactions}.png "$site/screenshots/"
install -m 644 Sources/WalletCore/Resources/AssetLogos/asset-{eth,btc,sol,trx,ltc,xmr}.png "$site/networks/"
