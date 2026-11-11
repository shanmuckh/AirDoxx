#!/bin/bash
# Commits the working tree, pushes, tags, and publishes a GitHub release with the DMG.
# Run after ./scripts/build_app.sh --release. Uses the GitHub login already saved for git.
#
#   bash scripts/publish_release.sh 2.1.0 "AirDoxx 2.1"
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: publish_release.sh <version> <title>}"
TITLE="${2:-AirDoxx $VERSION}"
TAG="v$VERSION"
REPO="shanmuckh/AirDoxx"
DMG="build/AirDoxx.dmg"
NOTES="build/release-notes-$VERSION.md"
[[ -f "$DMG" ]] || { echo "Build the DMG first: ./scripts/build_app.sh --release"; exit 1; }

echo "==> Commit & push"
git add -A
git commit -F scripts/release-message.txt 2>/dev/null || echo "   (nothing to commit)"
git tag -a "$TAG" -m "$TITLE" 2>/dev/null || echo "   (tag $TAG already exists)"
git push origin main --follow-tags

echo "==> Publishing release $TAG"
TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p')"
api() { curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
             -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

SUM="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
printf '%s\n\nSHA-256 of AirDoxx.dmg: %s\n' "$(cat "$NOTES" 2>/dev/null || echo "$TITLE")" "$SUM" > "/tmp/airdoxx-notes.md"

BODY="$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' /tmp/airdoxx-notes.md)"
REL="$(api -X POST "https://api.github.com/repos/$REPO/releases" \
  -d "{\"tag_name\":\"$TAG\",\"name\":\"$TITLE\",\"body\":$BODY,\"make_latest\":\"true\"}")"
UPLOAD="$(echo "$REL" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')"
api -X POST "$UPLOAD?name=AirDoxx.dmg" -H "Content-Type: application/x-apple-diskimage" --data-binary @"$DMG" >/dev/null
echo "==> Published: https://github.com/$REPO/releases/tag/$TAG"
