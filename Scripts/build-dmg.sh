#!/bin/bash
# Native hdiutil packaging; no Finder automation or wallet launch.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = --help ]; then
    echo 'Usage: ./Scripts/build-dmg.sh [--skip-build]'
    echo 'Builds and verifies an arm64 development DMG in build/.'
    exit 0
fi
[ "$#" -le 1 ] && { [ "$#" -eq 0 ] || [ "$1" = --skip-build ]; } || { echo 'Use --skip-build or no argument' >&2; exit 1; }
[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || { echo 'DMG currently requires macOS arm64' >&2; exit 1; }
for command in hdiutil ditto codesign python3 plutil lipo git; do command -v "$command" >/dev/null || exit 1; done
if [ "${1:-}" != --skip-build ]; then ./Scripts/build-app.sh release; fi
app="$PWD/build/Veil Wallet.app"
python3 Scripts/verify-app.py "$app"
lipo -verify_arch arm64 "$app/Contents/MacOS/VeilWallet"
version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
case "$version" in ''|*[!0-9A-Za-z.-]*) echo 'Invalid application version' >&2; exit 1 ;; esac
name="VeilWallet-$version-macOS-arm64.dmg"
staging=$(mktemp -d "$PWD/build/.dmg.XXXXXX")
mount_point="$staging/mounted"
attached=0
cleanup() {
    result=$?
    trap - EXIT
    if [ "$attached" = 1 ]; then
        if ! hdiutil detach "$mount_point" -quiet; then
            echo 'Could not detach verification disk; preserving staging directory' >&2
            exit 1
        fi
    fi
    rm -rf "$staging"
    exit "$result"
}
trap cleanup EXIT
mkdir -p "$staging/content" "$mount_point"
ditto --norsrc --noextattr "$app" "$staging/content/Veil Wallet.app"
ln -s /Applications "$staging/content/Applications"
cat > "$staging/content/Install.txt" <<'TEXT'
Veil Wallet · macOS 14+ · Apple Silicon

Drag Veil Wallet.app into Applications, then eject this disk image.
This is a development preview with ad-hoc signing and no Apple notarization.
If macOS blocks opening it, verify the source and SHA256 checksum, then follow
System Settings > Privacy & Security. Do not disable Gatekeeper.
Never store funds using a published test seed phrase.

Wallet data stays in the user's Application Support directory.
This installer contains no user wallet or private keys.
Licenses and third-party notices are bundled in Contents/Resources.
TEXT
codesign --verify --deep --strict "$staging/content/Veil Wallet.app"
hdiutil create -quiet -volname 'Veil Wallet' -srcfolder "$staging/content" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$staging/$name"
hdiutil verify -quiet "$staging/$name"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount_point" "$staging/$name"
attached=1
python3 Scripts/verify-app.py "$mount_point/Veil Wallet.app"
python3 - "$app" "$mount_point" <<'PY'
import hashlib, os, sys
from pathlib import Path
original, mounted = map(Path, sys.argv[1:])
assert (mounted / 'Applications').is_symlink()
assert os.readlink(mounted / 'Applications') == '/Applications'
assert (mounted / 'Install.txt').is_file()
def inventory(root):
    result = {}
    for p in root.rglob('*'):
        key = p.relative_to(root).as_posix()
        if p.is_symlink(): result[key] = ('link', os.readlink(p))
        elif p.is_file(): result[key] = ('file', hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mode & 0o777)
    return result
assert inventory(original) == inventory(mounted / 'Veil Wallet.app'), 'DMG application differs from verified build'
print('DMG mounted read-only: application contents, permissions and Applications link verified')
PY
hdiutil detach -quiet "$mount_point"
attached=0
mv "$staging/$name" "$PWD/build/$name"
python3 - "$version" <<'PY'
import hashlib, json, platform, subprocess, sys
from pathlib import Path
version=sys.argv[1]; out=Path('build')
def command(args):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL).decode().strip()
def optional(args):
    try: return command(args)
    except subprocess.CalledProcessError: return None
index_tree=command(['git','write-tree'])
head_tree=optional(['git','rev-parse','HEAD^{tree}'])
worktree_clean=subprocess.run(['git','diff','--quiet'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
untracked=command(['git','ls-files','--others','--exclude-standard'])
source_tree=index_tree if worktree_clean and not untracked else None
committed=source_tree is not None and source_tree == head_tree
info=dict(version=version, architecture='arm64', minimumMacOS='14.0',
          signing='ad-hoc' if __import__('os').environ.get('VEIL_SIGNING_IDENTITY', '-') == '-' else 'custom identity; notarization not performed by this script',
          notarized=False, sourceCommit=optional(['git','rev-parse','--verify','HEAD']) if committed else None,
          sourceTree=source_tree, dirty=not committed, macOS=platform.mac_ver()[0],
          swift=command(['swift','--version']).splitlines(), go=command(['./Scripts/go.sh','version']),
          runtimeVersions={'Tor':'0.4.9.15','TorExpertBundle':'16.0','Monero':'0.18.5.4','Node':'24.22.2'})
(out/'BUILD-INFO.json').write_text(json.dumps(info,indent=2)+'\n')
names=[f'VeilWallet-{version}-macOS-arm64.dmg', f'VeilWallet-{version}-macOS-arm64.zip', 'BUILD-INFO.json']
source=f'VeilWallet-{version}-source.tar.gz'
if (out/source).is_file(): names.append(source)
lines=[]
for name in names:
    path=out/name
    if not path.is_file(): raise SystemExit('Missing expected package output')
    lines.append(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+name)
(out/'SHA256SUMS').write_text('\n'.join(lines)+'\n')
PY
echo "DMG verified: build/$name"
echo 'Checksums: build/SHA256SUMS'
