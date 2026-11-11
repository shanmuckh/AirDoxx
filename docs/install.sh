#!/bin/bash
# AirDoxx installer.  Usage:
#   curl -fsSL https://shanmuckh.github.io/AirDoxx/install.sh | bash
#
# Downloads AirDoxx, copies it into Applications and opens it. Nothing runs as admin,
# nothing else on your Mac is changed. Read it before you run it - it's short.
set -euo pipefail

URL="${AIRDOXX_DMG_URL:-https://shanmuckh.github.io/AirDoxx/download/AirDoxx.dmg}"
APP="AirDoxx.app"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1mAirDoxx:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "AirDoxx is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$major" -ge 14 ]] || fail "AirDoxx needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
  [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say "Downloading AirDoxx"
curl -fL --progress-bar "$URL" -o "$WORK/AirDoxx.dmg" || fail "Download failed. Check your internet connection."

say "Opening the disk image"
MOUNT="$WORK/mount"
mkdir "$MOUNT"
hdiutil attach "$WORK/AirDoxx.dmg" -nobrowse -readonly -quiet -mountpoint "$MOUNT" || fail "The download looks damaged. Try again."
[[ -d "$MOUNT/$APP" ]] || fail "AirDoxx wasn't found in the download."

DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

if pgrep -xq AirDoxx; then
  say "Closing the running AirDoxx"
  osascript -e 'tell application "AirDoxx" to quit' >/dev/null 2>&1 || true
  sleep 1
fi

say "Installing to $DEST"
rm -rf "$DEST/$APP.new"
ditto "$MOUNT/$APP" "$DEST/$APP.new"
rm -rf "$DEST/$APP"
mv "$DEST/$APP.new" "$DEST/$APP"
# Only AirDoxx's own "downloaded from the internet" mark, if it has one.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

version="$(defaults read "$DEST/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")"
say "AirDoxx $version is installed. Opening it now."
open "$DEST/$APP"
