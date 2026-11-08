#!/bin/bash
# Builds "AirDox.app" into ./build.
# Bundles adb and the scrcpy server if they're installed (Homebrew or env vars), so the app is self-contained.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AirDox"
APP="build/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> Compiling (release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/AirDox"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/AirDox"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>local.androidmirroring.app</string>
    <key>CFBundleExecutable</key><string>AirDox</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Mirrors Android phones using the open-source scrcpy server (Apache-2.0).</string>
</dict>
</plist>
PLIST

echo "==> Rendering icon"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

# --- scrcpy server -----------------------------------------------------------
SERVER="${SCRCPY_SERVER_PATH:-}"
VERSION="${SCRCPY_SERVER_VERSION:-}"
if [[ -z "$SERVER" ]]; then
    for p in /opt/homebrew/share/scrcpy/scrcpy-server /usr/local/share/scrcpy/scrcpy-server; do
        [[ -f "$p" ]] && SERVER="$p" && break
    done
fi
if [[ -n "$SERVER" && -z "$VERSION" ]]; then
    REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$SERVER")"
    VERSION="$(echo "$REAL" | sed -nE 's#.*/Cellar/scrcpy/([^/_]+)(_[0-9]+)?/.*#\1#p')"
fi
if [[ -n "$SERVER" && -n "$VERSION" ]]; then
    echo "==> Bundling scrcpy server $VERSION"
    cp "$SERVER" "$CONTENTS/Resources/scrcpy-server"
    echo "$VERSION" > "$CONTENTS/Resources/scrcpy-server.version"
else
    echo "!!  scrcpy server not found: the app will look for a Homebrew install at runtime (brew install scrcpy)"
fi

# --- adb -----------------------------------------------------------------------
ADB_BIN="${ADB:-$(command -v adb || true)}"
[[ -z "$ADB_BIN" && -x /opt/homebrew/bin/adb ]] && ADB_BIN=/opt/homebrew/bin/adb
if [[ -n "$ADB_BIN" ]]; then
    echo "==> Bundling adb from $ADB_BIN"
    mkdir -p "$CONTENTS/Resources/platform-tools"
    cp "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$ADB_BIN")" "$CONTENTS/Resources/platform-tools/adb"
else
    echo "!!  adb not found: the app will ask for it at runtime (brew install --cask android-platform-tools)"
fi

# --- Signing ---------------------------------------------------------------------
# macOS ties the Accessibility permission (needed for the Mac function keys) to the app's
# signature. Ad-hoc signatures change on every build, which silently revokes the permission.
# So sign with a stable, self-signed identity kept in a project-local keychain (.signing/),
# never touching the login keychain or system trust settings.
SIGN_DIR=".signing"
KC="$PWD/$SIGN_DIR/AndroidMirroring.keychain-db"
IDENTITY="Android Mirroring Local Signing"
if [[ ! -f "$KC" ]]; then
    echo "==> Creating local signing identity in $SIGN_DIR/"
    mkdir -p "$SIGN_DIR"
    openssl rand -hex 16 > "$SIGN_DIR/keychain-password"
    PW="$(cat "$SIGN_DIR/keychain-password")"
    cat > "$SIGN_DIR/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SIGN_DIR/key.pem" -out "$SIGN_DIR/cert.pem" \
        -days 3650 -config "$SIGN_DIR/cert.cnf" 2>/dev/null
    openssl pkcs12 -export -inkey "$SIGN_DIR/key.pem" -in "$SIGN_DIR/cert.pem" -out "$SIGN_DIR/id.p12" \
        -passout "pass:$PW" -legacy 2>/dev/null \
      || openssl pkcs12 -export -inkey "$SIGN_DIR/key.pem" -in "$SIGN_DIR/cert.pem" -out "$SIGN_DIR/id.p12" -passout "pass:$PW"
    # Remember the search list so creating the keychain can't change it.
    SEARCH_LIST="$(security list-keychains -d user | tr -d '"')"
    security create-keychain -p "$PW" "$KC"
    security list-keychains -d user -s $SEARCH_LIST
    security unlock-keychain -p "$PW" "$KC"
    security import "$SIGN_DIR/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null 2>&1
    rm -f "$SIGN_DIR/id.p12" "$SIGN_DIR/key.pem"
fi

PW="$(cat "$SIGN_DIR/keychain-password")"
security unlock-keychain -p "$PW" "$KC"
if codesign --force --deep --keychain "$KC" --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "==> Signed with stable local identity"
else
    echo "!!  Stable signing failed; falling back to ad-hoc (Accessibility permission resets on rebuild)"
    codesign --force --deep --sign - "$APP" >/dev/null
fi

echo "==> Done: $APP"
