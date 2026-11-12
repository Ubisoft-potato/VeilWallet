#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=16.0
fingerprint=EF6E286DDA85EA2A4BA7DE684E2C6E8793298290
case "$(uname -m)" in
    arm64) arch=aarch64; expected=b8da251eccbe9e82f3681ee3af3c97fb4291c4a4e153e5b824bde48a1117cd6a ;;
    x86_64) arch=x86_64; expected=5b1860215c26f2d408392d1d79e798a2f81d65eb939510bb94c11f237bd0bfc3 ;;
    *) echo "Unsupported architecture" >&2; exit 1 ;;
esac
command -v gpg >/dev/null || { echo 'Install GnuPG first: brew install gnupg' >&2; exit 1; }
mkdir -p Vendor .build/gnupg
chmod 700 .build/gnupg
archive="tor-expert-bundle-macos-$arch-$version.tar.gz"
base="https://archive.torproject.org/tor-package-archive/torbrowser/$version"
# dist.torproject.org rotates older releases out of its live directory. Pin
# historical releases to Tor's official archive, with the same hash and signer.
fetch() {
    echo "Fetching verified-release input: $1"
    /usr/bin/curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 "$1" -o "$2.partial"
    mv "$2.partial" "$2"
}
# This is a developer-only fetch. The installed app never downloads executables.
if [ ! -f "Vendor/$archive" ]; then fetch "$base/$archive" "Vendor/$archive"; fi
actual=$(shasum -a 256 "Vendor/$archive" | awk '{print $1}')
[ "$actual" = "$expected" ] || { echo 'Tor SHA-256 mismatch' >&2; exit 1; }
fetch "$base/$archive.asc" "Vendor/$archive.asc"
if [ ! -f Vendor/tor-browser-release-key.asc ]; then
    fetch "https://keys.openpgp.org/vks/v1/by-fingerprint/$fingerprint" Vendor/tor-browser-release-key.asc
fi
gpg --batch --no-autostart --homedir .build/gnupg --import Vendor/tor-browser-release-key.asc 2>.build/tor-key-import.log || {
    # Public-key import may return nonzero solely because sandboxed gpg-agent cannot start.
    gpg --batch --no-autostart --homedir .build/gnupg --list-keys "$fingerprint" >/dev/null
}
gpg --batch --no-autostart --homedir .build/gnupg --status-fd 1 --verify "Vendor/$archive.asc" "Vendor/$archive" > .build/tor-signature-status.txt
awk -v fp="$fingerprint" '$2 == "VALIDSIG" && $NF == fp { ok=1 } END { exit !ok }' .build/tor-signature-status.txt
mkdir -p Vendor/Tor
tar -xzf "Vendor/$archive" -C Vendor/Tor
# Tor release binaries have linker signatures; ad-hoc re-sign for local macOS execution.
find Vendor/Tor/tor -type f -print0 | while IFS= read -r -d '' file; do
    if /usr/bin/file "$file" | /usr/bin/grep -q 'Mach-O'; then /usr/bin/codesign --force --sign - "$file"; fi
done
Vendor/Tor/tor/tor --version
echo "Tor $version verified and prepared for $arch."
