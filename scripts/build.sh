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

IDENTITY=${TALARIA_SIGN_IDENTITY:-${HERMES_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}}
if [[ -n "$IDENTITY" ]]; then
  step "Signing Alaria.app" codesign --force --options runtime --timestamp --entitlements Resources/Hermes.entitlements --sign "$IDENTITY" "$APP"
  step "Verifying signature" codesign --verify --strict --verbose=2 "$APP"
else
  codesign --force --options runtime --entitlements Resources/Hermes.entitlements --sign - "$APP"
fi
echo "✓ $APP  (v$VERSION, signed: ${IDENTITY:-ad-hoc})"
