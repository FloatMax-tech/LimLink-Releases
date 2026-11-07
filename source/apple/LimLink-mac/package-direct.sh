#!/bin/bash
# Package an already built, signed and notarized Cloud app. Never builds or runs it.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'Usage: package-direct.sh /absolute/path/LimLink.app /absolute/output/folder' >&2
  exit 2
fi
app="$1"
output="$2"
[[ "$app" = /* && "$output" = /* && -d "$app/Contents" ]] || { echo 'Absolute app/output paths required' >&2; exit 2; }
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
channel=$(/usr/libexec/PlistBuddy -c 'Print LimLinkDistributionChannel' "$plist")
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$bundle" = 'com.limlink.dev' ]] || { echo 'Wrong version/bundle' >&2; exit 1; }
[[ "$channel" = Direct ]] || { echo 'Not a website edition' >&2; exit 1; }
executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")
for architecture in arm64 x86_64; do
  /usr/bin/lipo "$app/Contents/MacOS/$executable" -verify_arch "$architecture"
done
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
signature=$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)
[[ "$signature" = *'Authority=Developer ID Application:'* && "$signature" = *'TeamIdentifier=J8PZU3W5VL'* && "$signature" = *'runtime'* ]] || { echo 'Developer ID/hardened runtime mismatch' >&2; exit 1; }
/usr/bin/xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app"
mkdir -p "$output"
name="LimLink-$version-macOS"
[[ ! -e "$output/$name.zip" && ! -e "$output/$name.dmg" && ! -e "$output/$name-manifest.json" ]] || { echo 'Delivery already exists; choose a new output folder' >&2; exit 1; }
packaging_python="${LIMLINK_PACKAGING_PYTHON:-python3}"
helper="$(cd "$(dirname "$0")" && pwd)/installer/layout.py"
"$packaging_python" -c 'import PIL, ds_store, mac_alias'
stage=$(mktemp -d "${TMPDIR:-/tmp}/limlink-direct.XXXXXX")
mounted=''
cleanup() {
  if [[ -n "$mounted" ]]; then /usr/bin/hdiutil detach "$mounted" >/dev/null 2>&1 || true; fi
  rm -rf "$stage"
}
trap cleanup EXIT
mkdir -p "$stage/content/.background"
/usr/bin/ditto "$app" "$stage/content/LimLink.app"
ln -s /Applications "$stage/content/Applications"
"$packaging_python" "$helper" background "$channel" "$stage/content/.background/installer.tiff"
# A real writable volume is essential: background Alias CNIDs must belong to this image.
app_kb=$(/usr/bin/du -sk "$app" | /usr/bin/awk '{print $1}')
image_mb=$((app_kb / 1024 + 40))
(( image_mb >= 64 )) || image_mb=64
/usr/bin/hdiutil create -size "${image_mb}m" -fs HFS+ -volname "LimLink $version" -type UDIF -nospotlight "$stage/writable.dmg"
mkdir "$stage/mount"
/usr/bin/hdiutil attach "$stage/writable.dmg" -mountpoint "$stage/mount" -nobrowse -noautoopen
mounted="$stage/mount"
/usr/bin/ditto "$stage/content/" "$mounted/"
"$packaging_python" "$helper" layout "$mounted"
# Finder metadata and installation artwork live outside the sealed app.
/usr/bin/codesign --verify --deep --strict --verbose=2 "$mounted/LimLink.app"
/usr/bin/xcrun stapler validate "$mounted/LimLink.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$mounted/LimLink.app"
/bin/sync
/usr/bin/hdiutil detach "$mounted"
mounted=''
/usr/bin/hdiutil convert "$stage/writable.dmg" -format UDZO -imagekey zlib-level=9 -o "$output/$name.dmg"
/usr/bin/hdiutil verify "$output/$name.dmg"
"$packaging_python" "$helper" guide "$output/Install-LimLink.html"
mkdir -p "$stage/delivery/$name"
/usr/bin/ditto "$output/$name.dmg" "$stage/delivery/$name/$name.dmg"
/usr/bin/ditto "$output/Install-LimLink.html" "$stage/delivery/$name/Install-LimLink.html"
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")
cat > "$stage/delivery/$name/README.txt" <<EOF
LimLink $version — macOS installer
1. Open $name.dmg.
2. Drag LimLink into Applications, then open it from Applications.
Nine-language offline instructions: Install-LimLink.html

Application: LimLink $version build $build, channel $channel.
The app's verified Developer ID signature and stapled notarization ticket
are preserved. Packaging does not rebuild or modify the sealed application.
This newly created DMG has not itself been notarized.
EOF
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage/delivery/$name" "$output/$name.zip"
/usr/bin/shasum -a 256 "$output/$name.zip" "$output/$name.dmg" > "$output/$name-SHA256SUMS.txt"
"$packaging_python" - "$output/$name.dmg" "$output/$name-manifest.json" "$version" "$channel" "$build" <<'PYCODE'
import hashlib, json, pathlib, sys
package, destination = map(pathlib.Path, sys.argv[1:3])
version, channel, build = sys.argv[3:]
key = 'macos'
hasher = hashlib.sha256()
with package.open('rb') as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b''):
        hasher.update(chunk)
digest = hasher.hexdigest()
entry = {key: {'version': version, 'url': '/download/'+key, 'size': package.stat().st_size, 'sha256': digest}}
destination.write_text(json.dumps(entry, indent=2)+'\n')
(package.parent / (package.stem + '-packaging.json')).write_text(json.dumps({
    'appVersion': version, 'appBuild': build, 'channel': channel,
    'packagingStepBuiltApp': False,
    'appSignatureAndStapledTicketVerified': True, 'dmgItselfNotarized': False,
    'finderLayout': '640x440; two icons; image-local background alias',
    'zipContents': ['DMG', 'nine-language offline HTML guide', 'README'],
}, indent=2)+'\n')
PYCODE
echo "Verified existing app repackaged: $output/$name.dmg"
echo "Installer ZIP and offline guide: $output/$name.zip"
echo 'The supplied notarized app was packaged without rebuilding; the DMG itself was not notarized.'
