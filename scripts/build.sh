#!/bin/zsh
# Build Alaria.app (SwiftPM -> bundle -> signed). Alaria is a Mac client for Hermes Agent.
#   VERSION=0.2.0 BUILD=2 ./scripts/build.sh
#   TALARIA_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/build.sh
# CI (.github/workflows/release.yml) sets VERSION/BUILD and TALARIA_SIGN_IDENTITY from a throwaway keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
CONFIG=${CONFIG:-release}
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-1}
export MACOSX_DEPLOYMENT_TARGET=26.0

echo "▸ Swift ($CONFIG, v$VERSION build $BUILD)"
if ! LOG=$(swift build -c "$CONFIG" --arch arm64 --product HermesMac 2>&1); then
  ERRS=$(echo "$LOG" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "error:" | sort -u)
  echo "$ERRS"; annotate error "Swift build failed" "$ERRS"; echo "✗ build failed"; exit 1
fi
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/HermesMac"

APP=build/Alaria.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Alaria"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  echo "▸ Icon"
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle (auto-update, hermes-mac-d3k) ships as a binary xcframework via SwiftPM; embed it next to the executable.
SPARKLE_FW=$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework 2>/dev/null | head -1)
[[ -d "$SPARKLE_FW" ]] || { annotate error "Sparkle missing" "Sparkle.framework not found under .build/artifacts"; echo "✗ Sparkle.framework not found"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

IDENTITY=${TALARIA_SIGN_IDENTITY:-${HERMES_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}}

# AIDEV-NOTE: sign Sparkle inside-out (XPCs, Autoupdate, Updater.app, framework) BEFORE the app; never --deep.
# Order and flags follow Sparkle's "Distributing outside Xcode" docs (same as Murmur).
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign_sparkle() {   # $1 = identity ("-" for ad-hoc)
  local ts=(); [[ "$1" != "-" ]] && ts=(--timestamp)
  step "Signing Sparkle Installer.xpc" codesign -f -s "$1" -o runtime $ts "$SP/XPCServices/Installer.xpc"
  step "Signing Sparkle Downloader.xpc" codesign -f -s "$1" -o runtime $ts --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
  step "Signing Sparkle Autoupdate" codesign -f -s "$1" -o runtime $ts "$SP/Autoupdate"
  step "Signing Sparkle Updater.app" codesign -f -s "$1" -o runtime $ts "$SP/Updater.app"
  step "Signing Sparkle.framework" codesign -f -s "$1" -o runtime $ts "$APP/Contents/Frameworks/Sparkle.framework"
}
sign_sparkle "${IDENTITY:--}"

if [[ -n "$IDENTITY" ]]; then
  step "Signing Alaria.app" codesign --force --options runtime --timestamp --entitlements Resources/Hermes.entitlements --sign "$IDENTITY" "$APP"
  step "Verifying signature" codesign --verify --deep --strict --verbose=2 "$APP"
else
  codesign --force --options runtime --entitlements Resources/Hermes.entitlements --sign - "$APP"
fi
echo "✓ $APP  (v$VERSION, signed: ${IDENTITY:-ad-hoc})"
