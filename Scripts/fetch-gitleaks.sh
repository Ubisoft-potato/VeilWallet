#!/bin/bash
# Developer-only download. Does not upload repository contents.
set -euo pipefail
cd "$(dirname "$0")/.."
version=8.30.1
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) platform=darwin_arm64; expected=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
    Darwin/x86_64) platform=darwin_x64; expected=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
    Linux/x86_64) platform=linux_x64; expected=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
    *) echo 'Unsupported Gitleaks bootstrap platform' >&2; exit 1 ;;
esac
destination="$PWD/.tools/gitleaks"
mkdir -p "$destination" .build/audit-downloads
archive="$PWD/.build/audit-downloads/gitleaks-$version-$platform.tar.gz"
if [ ! -f "$archive" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 "https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_${platform}.tar.gz" -o "$archive.partial"
    mv "$archive.partial" "$archive"
fi
printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$destination" gitleaks LICENSE
"$destination/gitleaks" version
