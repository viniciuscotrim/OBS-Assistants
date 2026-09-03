#!/bin/bash
# build_dmg.sh — builds BambuStreamOverlay in release mode, assembles it
# into a proper .app bundle, signs it, and packages a reinstallable .dmg
# into ./dist. Re-run any time; every step overwrites its own output.
#
# Signing: uses the local "BambuStreamOverlay Local Dev" self-signed
# code-signing identity if present in the login keychain, falling back to
# ad-hoc (--sign -) if it isn't. This matters in practice: ad-hoc signing
# gets a *different* signature on every single build, which macOS treats
# as a different app each time — anything tied to that identity (notably
# Keychain items, like the printer's saved Access Code) stops resolving
# and you have to re-enter it after every rebuild. A stable local identity
# fixes that for good. One-time setup, if the identity doesn't exist yet:
#   openssl genrsa -out /tmp/bso.key 2048
#   openssl req -new -x509 -key /tmp/bso.key -out /tmp/bso.crt -days 3650 \
#     -subj "/CN=BambuStreamOverlay Local Dev" \
#     -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -out /tmp/bso.p12 -inkey /tmp/bso.key -in /tmp/bso.crt \
#     -passout pass:temp -legacy   # -legacy: macOS's Security framework can't
#                                  # read the modern PKCS12 cipher OpenSSL 3 defaults to
#   security import /tmp/bso.p12 -k ~/Library/Keychains/login.keychain-db \
#     -P temp -T /usr/bin/codesign -A
#   security add-trusted-cert -r trustRoot -p codeSign \
#     -k ~/Library/Keychains/login.keychain-db /tmp/bso.crt
#   rm /tmp/bso.key /tmp/bso.crt /tmp/bso.p12
#
# Requirements: Swift toolchain (Xcode or Xcode Command Line Tools),
# create-dmg (`brew install create-dmg`).
set -euo pipefail

SIGNING_IDENTITY="BambuStreamOverlay Local Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
    SIGNING_IDENTITY="-" # ad-hoc fallback
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="BambuStreamOverlay"
BUNDLE_ID="com.bambustreamoverlay.app"
INFO_PLIST_SRC="Sources/BambuStreamOverlay/App/Info.plist"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST_SRC" 2>/dev/null || echo "1.0.0")"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

echo "==> Building $APP_NAME v$VERSION (release)"

# Prefer a universal (arm64 + x86_64) binary; fall back to the host's native
# architecture if the second slice's SDK isn't available in this toolchain.
if swift build -c release --arch arm64 --arch x86_64 2>/tmp/bso_build_universal.log; then
    BUILD_DIR=".build/apple/Products/Release"
    if [ ! -f "$BUILD_DIR/$APP_NAME" ]; then
        # Older SwiftPM layouts place the universal binary here instead.
        BUILD_DIR=".build/release"
    fi
    echo "    universal build ok"
else
    echo "    universal build not available here, falling back to native arch:"
    tail -n 20 /tmp/bso_build_universal.log || true
    swift build -c release
    BUILD_DIR=".build/release"
fi

BIN_PATH="$BUILD_DIR/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Signing (identity: $SIGNING_IDENTITY)"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE"

echo "==> Packaging .dmg"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "error: create-dmg not found. Install with: brew install create-dmg" >&2
    exit 1
fi

create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 600 380 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 150 180 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 450 180 \
    --overwrite \
    "$DMG_PATH" \
    "$APP_BUNDLE" \
    || {
        echo "warning: create-dmg failed (this can happen in a headless/CI shell" >&2
        echo "since it drives Finder to lay out the volume icon). Run this script" >&2
        echo "from a normal Terminal on your Mac, or ship $APP_BUNDLE directly." >&2
        exit 1
    }

echo ""
echo "==> Done"
echo "    App: $APP_BUNDLE"
echo "    DMG: $DMG_PATH"
echo ""
echo "Not notarized (self-signed/local identity, not an Apple Developer cert) —"
echo "on first launch macOS Gatekeeper will block it. Either right-click the"
echo "app > Open (once), or:"
echo "    xattr -cr \"$APP_BUNDLE\""
