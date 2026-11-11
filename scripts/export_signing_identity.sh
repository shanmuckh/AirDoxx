#!/bin/bash
# Lets GitHub Actions sign builds with the same identity as this Mac, so macOS keeps the
# Accessibility permission when people update between local and CI builds.
#
#   bash scripts/export_signing_identity.sh
#
# It copies the first secret to the clipboard and tells you where the second one is.
# Add both at  GitHub > repo > Settings > Secrets and variables > Actions:
#   SIGNING_P12_BASE64     (the clipboard)
#   SIGNING_P12_PASSWORD   (contents of .signing/keychain-password)
# Nothing is printed, uploaded or left on disk.
set -euo pipefail
cd "$(dirname "$0")/.."

KC="$PWD/.signing/AndroidMirroring.keychain-db"
[[ -f "$KC" ]] || { echo "No local signing identity yet. Run ./scripts/build_app.sh once first."; exit 1; }

PW="$(cat .signing/keychain-password)"
OUT="$(mktemp -d)/id.p12"
trap 'rm -f "$OUT"' EXIT

security unlock-keychain -p "$PW" "$KC"
security export -k "$KC" -t identities -f pkcs12 -P "$PW" -o "$OUT"
base64 -i "$OUT" | pbcopy

echo "SIGNING_P12_BASE64 is on your clipboard."
echo "SIGNING_P12_PASSWORD is the contents of .signing/keychain-password"
echo "  (copy it with:  tr -d '\n' < .signing/keychain-password | pbcopy )"
