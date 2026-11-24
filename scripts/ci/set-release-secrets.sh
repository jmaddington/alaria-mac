#!/bin/zsh
# One-time: copy the Developer ID + notary credentials (same ones Murmur uses) into this repo's Actions secrets.
#   scripts/ci/set-release-secrets.sh ~/path/DeveloperIDApplication.p12 ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8
# Prompts for the .p12 password and the App Store Connect issuer ID; nothing is echoed or written to disk.
set -euo pipefail
REPO=${REPO:-jmaddington/hermes-mac}
P12=${1:?usage: set-release-secrets.sh <DeveloperID.p12> <AuthKey_ID.p8>}
P8=${2:?usage: set-release-secrets.sh <DeveloperID.p12> <AuthKey_ID.p8>}
KEY_ID=${${P8:t:r}#AuthKey_}
# A bare certificate (Keychain "Export" of the cert alone, or .cer renamed) has no private key: CI can't sign with it.
if file -b "$P12" | grep -qi '^certificate'; then
  echo "✗ $P12 is only the certificate, without its private key."
  echo "  In Keychain Access > login > My Certificates, expand the Developer ID Application row (the key sits"
  echo "  under it), select the certificate, File > Export Items..., format Personal Information Exchange (.p12)."
  exit 1
fi
# AIDEV-NOTE: needs a real terminal; Claude Code's `!` prefix has no TTY, so read would hit EOF silently.
[[ -t 0 ]] || { echo "✗ run this in a Terminal window (it prompts for the password)"; exit 1; }
read -rs "PW?.p12 password: "; echo; export PW
# Fail fast on a wrong password, the way CI imports it (security handles Keychain's AES exports; LibreSSL may not).
KC=$(mktemp -u /tmp/p12check.XXXXXX).keychain-db
security create-keychain -p x "$KC" >/dev/null
trap 'security delete-keychain "$KC" 2>/dev/null' EXIT
security import "$P12" -k "$KC" -P "$PW" -x >/dev/null 2>&1 || { echo "✗ wrong .p12 password (or not a .p12)"; exit 1; }
security find-identity -v -p codesigning "$KC" | grep -q 'Developer ID Application' \
  || { echo "✗ the .p12 has no Developer ID Application identity (certificate + private key)"; exit 1; }
read -r "ISSUER?App Store Connect issuer ID (Users and Access › Integrations): "
base64 -i "$P12" | gh secret set DEVELOPER_ID_APP_P12 -R "$REPO"
print -rn -- "$PW" | gh secret set DEVELOPER_ID_APP_PASSWORD -R "$REPO"
gh secret set ASC_API_KEY_P8 -R "$REPO" < "$P8"
print -rn -- "$KEY_ID" | gh secret set ASC_API_KEY_ID -R "$REPO"
print -rn -- "$ISSUER" | gh secret set ASC_API_ISSUER_ID -R "$REPO"
gh secret list -R "$REPO"
