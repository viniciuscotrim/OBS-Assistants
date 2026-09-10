#!/bin/bash
# build_dmg.sh — builds OBS Assistants in release mode, assembles it
# into a proper .app bundle, signs it, notarizes it when possible, and
# packages a reinstallable .dmg into ./dist. Re-run any time; every step
# overwrites its own output.
#
# Signing identity, in order of preference:
#   1. "Developer ID Application: ..." — a real Apple Developer Program
#      certificate (needs a paid account). Signed with the hardened
#      runtime + entitlements (required for notarization) and, when a
#      notarytool keychain profile is present (see below), notarized and
#      stapled automatically. This is the real fix, for everyone: a
#      stable, Apple-trusted identity across every build/update, and no
#      Gatekeeper "unidentified developer" warning for anyone who
#      downloads it.
#   2. "OBS Assistants Local Dev" — a self-signed local-only identity (see
#      git history for the one-time setup). Fixes the *this-machine's*
#      Keychain-item-invalidated-on-rebuild problem (a stable signing
#      identity survives rebuilds even though each build's raw CDHash
#      differs — Keychain ACLs are evaluated against the *identity*, not
#      the exact binary hash) but does NOT clear the Gatekeeper warning
#      for anyone else, since it isn't Apple-trusted.
#   3. Ad-hoc (--sign -) — the fallback if neither exists. Gets a
#      genuinely different signature on every single build, which macOS
#      treats as a different app each time: anything tied to that
#      identity (notably Keychain items, like the printer's saved Access
#      Code) stops resolving and you have to re-enter it after every
#      rebuild.
#
# One-time notarization setup (once you have a Developer ID Application
# certificate installed — see README "Distribuição" for the full
# walkthrough): create an app-specific password at appleid.apple.com, then
#   xcrun notarytool store-credentials "OBSAssistantsNotary" \
#     --apple-id "you@example.com" --team-id "YOURTEAMID" --password "app-specific-password"
# stores it in your Keychain under that profile name — this script looks
# for exactly that name and notarizes automatically whenever it's present
# and the app was signed with a real Developer ID identity. No password
# ever touches this script.
#
# Requirements: Swift toolchain (Xcode or Xcode Command Line Tools) only.
# `create-dmg` (`brew install create-dmg`) is optional — used for a nicer
# .dmg (custom icon layout/background) when present; otherwise this falls
# back to a plain .dmg via `hdiutil` alone, which ships with macOS.
set -euo pipefail

NOTARY_PROFILE="OBSAssistantsNotary"
ENTITLEMENTS="Sources/OBSAssistants/App/OBSAssistants.entitlements"

# Command Line Tools 27.0 (installed 2026-09-10) ships a macOS 27.0 SDK
# whose SwiftUI module requires an external "SwiftUIMacros" compiler
# plugin (for @State/@Binding/etc., now macro-based) that only ships
# inside full Xcode.app — not present in a bare CLT install, which is all
# this machine has. Building against that default SDK fails on every
# single @State declaration in the app ("external macro implementation
# type 'SwiftUIMacros.StateMacro' could not be found"). The CLT install
# still carries the previous SDK (26.5) alongside the new one, and that
# one doesn't need the macro plugin — so pin SDKROOT to it explicitly
# rather than whatever `xcrun` picks by default. If this path stops
# existing after some future CLT update, either a newer SDK here has
# fixed the missing plugin (drop this override and confirm a plain
# `swift build` works again) or a full Xcode.app install is needed.
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi

SIGNING_IDENTITY=""
HARDENED_RUNTIME=false
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"(.*)"$/\1/')"
    HARDENED_RUNTIME=true
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "OBS Assistants Local Dev"; then
    SIGNING_IDENTITY="OBS Assistants Local Dev"
else
    SIGNING_IDENTITY="-" # ad-hoc fallback
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="OBS Assistants"
BIN_NAME="OBSAssistants" # Package.swift executable target name (no spaces)
BUNDLE_ID="com.obsassistants.app"
INFO_PLIST_SRC="Sources/OBSAssistants/App/Info.plist"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST_SRC" 2>/dev/null || echo "1.0.0")"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

echo "==> Building $APP_NAME v$VERSION (release)"

# Prefer a universal (arm64 + x86_64) binary; fall back to the host's native
# architecture if the second slice's SDK isn't available in this toolchain.
if swift build -c release --arch arm64 --arch x86_64 2>/tmp/oa_build_universal.log; then
    BUILD_DIR=".build/apple/Products/Release"
    if [ ! -f "$BUILD_DIR/$BIN_NAME" ]; then
        # Older SwiftPM layouts place the universal binary here instead.
        BUILD_DIR=".build/release"
    fi
    echo "    universal build ok"
else
    echo "    universal build not available here, falling back to native arch:"
    tail -n 20 /tmp/oa_build_universal.log || true
    swift build -c release
    BUILD_DIR=".build/release"
fi

BIN_PATH="$BUILD_DIR/$BIN_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$BIN_NAME"
cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Signing (identity: $SIGNING_IDENTITY)"
if [ "$HARDENED_RUNTIME" = true ]; then
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
else
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
fi
codesign --verify --verbose "$APP_BUNDLE"

echo "==> Packaging .dmg"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null 2>&1; then
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
            echo "since it drives Finder to lay out the volume icon). Falling back to" >&2
            echo "a plain hdiutil .dmg instead." >&2
            rm -f "$DMG_PATH"
        }
fi

if [ ! -f "$DMG_PATH" ]; then
    # No create-dmg (or it failed): a plain .dmg via hdiutil alone — no
    # custom icon layout/background, but fully functional (double-click,
    # drag the .app onto the Applications alias) and needs nothing beyond
    # what macOS ships. Good enough when `brew install create-dmg` isn't
    # an option (no network, no Homebrew) or is overkill for a quick build.
    echo "==> create-dmg not available — building a plain .dmg via hdiutil"
    STAGING_DIR="$(mktemp -d)"
    trap 'rm -rf "$STAGING_DIR"' EXIT
    cp -R "$APP_BUNDLE" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
fi

NOTARIZED=false
if [ "$HARDENED_RUNTIME" = true ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Notarizing (profile: $NOTARY_PROFILE) — this talks to Apple and can take a few minutes"
    if xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "==> Stapling notarization ticket"
        xcrun stapler staple "$DMG_PATH"
        # Staple the .app too — lets it work standalone (e.g. re-zipped),
        # not just when launched straight out of this .dmg.
        xcrun stapler staple "$APP_BUNDLE" || true
        NOTARIZED=true
    else
        echo "warning: notarization failed — shipping the signed-but-unnotarized .dmg." >&2
        echo "Run 'xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\"' for details." >&2
    fi
fi

echo ""
echo "==> Done"
echo "    App: $APP_BUNDLE"
echo "    DMG: $DMG_PATH"
echo ""
if [ "$NOTARIZED" = true ]; then
    echo "Notarized and stapled — Gatekeeper should accept it with no warning,"
    echo "for anyone, no xattr/right-click workaround needed."
elif [ "$HARDENED_RUNTIME" = true ]; then
    echo "Signed with a Developer ID identity but NOT notarized (no"
    echo "\"$NOTARY_PROFILE\" notarytool keychain profile found — see this"
    echo "script's header comment for the one-time setup). Until notarized,"
    echo "Gatekeeper still blocks it on first launch for anyone but you:"
    echo "    xattr -cr \"$APP_BUNDLE\""
else
    echo "Not notarized (self-signed/local identity, not an Apple Developer cert) —"
    echo "on first launch macOS Gatekeeper will block it. Either right-click the"
    echo "app > Open (once), or:"
    echo "    xattr -cr \"$APP_BUNDLE\""
fi
