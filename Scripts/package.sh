#!/bin/bash
# Build a release .app and wrap it in a DMG.
#
# WHAT THIS CANNOT DO ON THIS MACHINE, stated up front so nobody ships thinking
# it is done: notarization requires `notarytool` and `stapler`, which ship with
# Xcode. This machine has Command Line Tools only. Everything below produces an
# ad-hoc signed, UNNOTARIZED DMG — Gatekeeper will refuse it on any other Mac
# with "cannot be opened because the developer cannot be verified".
#
# To finish the job you need: Xcode installed, an Apple Developer ID Application
# certificate in the keychain, and an App Store Connect API key or app-specific
# password. Then the two missing steps are:
#
#   codesign --force --options runtime --timestamp \
#            --sign "Developer ID Application: <name> (<team>)" <app>
#   xcrun notarytool submit <dmg> --keychain-profile <profile> --wait
#   xcrun stapler staple <dmg>
#
# Hardened runtime note for whoever does that: this app spawns children under a
# pseudo-terminal and sends Apple Events, so it needs
# com.apple.security.automation.apple-events and must NOT be sandboxed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(grep -o '<string>[0-9.]*</string>' Scripts/bundle.sh | head -1 | tr -dc '0-9.')"
DMG="$ROOT/.build/VirtualCodexMicro-${VERSION:-0.1.0}.dmg"

echo "==> release build"
swift build -c release

echo "==> verifying before packaging"
VCM_SELFTEST=1 ./.build/release/VirtualCodexMicro

echo "==> bundling"
APP="$(./Scripts/bundle.sh release)"

echo "==> staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> dmg"
rm -f "$DMG"
hdiutil create -volname "Virtual Codex Micro" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo
echo "built: $DMG"
codesign -dv "$APP" 2>&1 | grep -E "Signature|Identifier" || true
echo
echo "NOT NOTARIZED — ad-hoc signature only. Gatekeeper will block this on"
echo "another Mac. See the header of this script for the remaining steps."
