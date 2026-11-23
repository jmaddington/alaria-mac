#!/bin/zsh
# Package build/Alaria.app into a drag-to-install DMG; sign, notarize and staple it when credentials are present;
# write SHA256SUMS. Adapted from Murmur's package.sh (DMG only; Alaria has no PKG/MDM flavor).
#
# Env:
#   VERSION                 version string (default: from the app's Info.plist)
#   TALARIA_SIGN_IDENTITY   "Developer ID Application: ..." (signs the DMG; default: first one in the keychain)
#   NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER   App Store Connect API key -> notarize + staple
#   DMG_NO_FINDER=1         skip create-dmg's Finder window layout (it pops Finder windows; use on a shared desktop)
#   Requires: brew install create-dmg
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
APP=build/Alaria.app
[[ -d $APP ]] || { echo "run scripts/build.sh first"; exit 1; }
VERSION=${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $APP/Contents/Info.plist)}
DIST=build/dist
rm -rf "$DIST" build/art
mkdir -p "$DIST" build/art
APP_ID=${TALARIA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}

echo "▸ Installer artwork"
swift scripts/make-installer-art.swift build/art
tiffutil -cathidpicheck build/art/dmg-background.png build/art/dmg-background@2x.png -out build/art/dmg-background.tiff >/dev/null

echo "▸ DMG"
DMG="$DIST/Alaria-$VERSION.dmg"
# create-dmg lays the window out via Finder; 448 = 420 pt of content + the title bar.
step "create-dmg" create-dmg --volname "Alaria" --volicon build/AppIcon.icns --background build/art/dmg-background.tiff \
  --window-pos 200 140 --window-size 660 448 --icon-size 112 --text-size 13 \
  --icon "Alaria.app" 178 196 --hide-extension "Alaria.app" --app-drop-link 482 196 \
  --no-internet-enable ${DMG_NO_FINDER:+--skip-jenkins} "$DMG" "$APP" >/dev/null
if [[ -n "$APP_ID" ]]; then step "Signing DMG" codesign --force --timestamp --sign "$APP_ID" "$DMG"; fi

if [[ -n "${NOTARY_KEY_PATH:-}" && -n "$APP_ID" ]]; then
  echo "▸ Notarizing $(basename "$DMG")"
  notarize "$DMG"
  step "Gatekeeper check (DMG)" spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  echo "▸ Skipping notarization (no Developer ID / API key)"
fi

(cd "$DIST" && shasum -a 256 *.dmg > SHA256SUMS.txt)
echo "✓ $(ls $DIST | tr '\n' ' ')"
