#!/bin/zsh
# One-time: copy the Developer ID + notary credentials (same ones Murmur uses) into this repo's Actions secrets.
#   scripts/ci/set-release-secrets.sh ~/path/DeveloperIDApplication.p12 ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8
# Prompts for the .p12 password and the App Store Connect issuer ID; nothing is echoed or written to disk.
set -euo pipefail
REPO=${REPO:-jmaddington/hermes-mac}
P12=${1:?usage: set-release-secrets.sh <DeveloperID.p12> <AuthKey_ID.p8>}
P8=${2:?usage: set-release-secrets.sh <DeveloperID.p12> <AuthKey_ID.p8>}
KEY_ID=${${P8:t:r}#AuthKey_}
# AIDEV-NOTE: needs a real terminal; Claude Code's `!` prefix has no TTY, so read would hit EOF silently.
[[ -t 0 ]] || { echo "✗ run this in a Terminal window (it prompts for the password)"; exit 1; }
read -rs "PW?.p12 password: "; echo; export PW
# Fail fast on a wrong password instead of finding out in CI.
openssl pkcs12 -in "$P12" -noout -passin env:PW 2>/dev/null || openssl pkcs12 -legacy -in "$P12" -noout -passin env:PW 2>/dev/null \
  || { echo "✗ wrong .p12 password (or not a .p12)"; exit 1; }
read -r "ISSUER?App Store Connect issuer ID (Users and Access › Integrations): "
base64 -i "$P12" | gh secret set DEVELOPER_ID_APP_P12 -R "$REPO"
print -rn -- "$PW" | gh secret set DEVELOPER_ID_APP_PASSWORD -R "$REPO"
gh secret set ASC_API_KEY_P8 -R "$REPO" < "$P8"
print -rn -- "$KEY_ID" | gh secret set ASC_API_KEY_ID -R "$REPO"
print -rn -- "$ISSUER" | gh secret set ASC_API_ISSUER_ID -R "$REPO"
gh secret list -R "$REPO"
