#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=0.18.5.4
case "$(uname -m)" in
    arm64) platform=armv8; expected=d457de7c8a1ad42e3232fdea6d9f9003be9652143fb8f719c1fc906aa6b4917b ;;
    x86_64) platform=x64; expected=9fefa7f5f7ae60fbd8d0ad18842b76c56ed161eca4ffb4f8b5f4800e5033b146 ;;
    *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
esac
filename="monero-mac-$platform-v$version.tar.bz2"
mkdir -p .build/monero-download Vendor/Monero
cache="$PWD/.build/monero-download"
if [ ! -f "$cache/$filename" ]; then curl --fail --location --proto '=https' --tlsv1.2 "https://downloads.getmonero.org/cli/$filename" -o "$cache/$filename.partial"; mv "$cache/$filename.partial" "$cache/$filename"; fi
printf '%s  %s\n' "$expected" "$cache/$filename" | shasum -a 256 -c -
# Keep the signed version-specific inventory: the website's current list changes
# when upstream publishes a newer version, while this build remains pinned.
cp "Configuration/RuntimeProvenance/monero-$version-hashes.txt" "$cache/hashes.txt"
keyring=$(mktemp -d "$cache/keyring.XXXXXX")
trap 'rm -rf "$keyring"' EXIT
chmod 700 "$keyring"
gpg --homedir "$keyring" --batch --no-options --yes --dearmor --output "$keyring/release.gpg" Vendor/monero-binaryfate.asc
fingerprint=$(gpg --homedir "$keyring" --batch --no-options --with-colons --show-keys Vendor/monero-binaryfate.asc | awk -F: '$1=="fpr" {print $10; exit}')
[ "$fingerprint" = 81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92 ] || { echo 'Unexpected Monero signing key' >&2; exit 1; }
gpgv --homedir "$keyring" --keyring "$keyring/release.gpg" "$cache/hashes.txt"
awk -v hash="$expected" -v name="$filename" '$1==hash && $2==name {found=1} END {exit !found}' "$cache/hashes.txt"
member=$(tar -tjf "$cache/$filename" | awk '/\/monero-wallet-rpc$/ {print; exit}')
[ -n "$member" ] || { echo 'Missing Monero RPC executable' >&2; exit 1; }
tar -xOjf "$cache/$filename" "$member" > Vendor/Monero/monero-wallet-rpc
chmod 755 Vendor/Monero/monero-wallet-rpc
for notice in LICENSE README.md ANONYMITY_NETWORKS.md; do
    tar -xOjf "$cache/$filename" "${member%/*}/$notice" > "Vendor/Monero/$notice"
done
cp "$cache/hashes.txt" Vendor/Monero/hashes.txt
printf '%s\n' "$version" > Vendor/Monero/VERSION
echo 'Verified Monero wallet runtime installed for development packaging.'
