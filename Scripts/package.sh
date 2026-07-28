#!/bin/bash
# Build a universal release .app and wrap it in a DMG.
#
# WHAT THIS CANNOT DO ON THIS MACHINE, stated up front so nobody ships thinking
# it is done. This produces an ad-hoc signed, UNNOTARIZED DMG — Gatekeeper will
# refuse it on any other Mac with "cannot be opened because the developer cannot
# be verified", and on macOS 15+ right-click-Open no longer bypasses that; the
# user has to go to System Settings > Privacy & Security and click Open Anyway.
#
# The blocker is NOT Xcode. `notarytool` and `stapler` both ship with Command Line
# Tools — an earlier version of this header claimed otherwise and it was wrong,
# which made the job look bigger than it is. The blocker is a certificate:
# `security find-identity -v -p codesigning` reports zero valid identities here,
# and a Developer ID Application certificate requires a paid Apple Developer
# account. Nothing else is missing.
#
# With that certificate the remaining steps are:
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

# Universal, because a download is not a local build: an arm64-only binary simply
# fails to launch on an Intel Mac, and `LSMinimumSystemVersion` 14.0 says we accept
# machines old enough to be Intel. SwiftPM's own `--arch` needs xcbuild from Xcode,
# but cross-compiling each slice with `--triple` and joining them with `lipo` needs
# nothing Xcode has.
echo "==> release build, both architectures"
swift build -c release
swift build -c release --triple x86_64-apple-macosx14.0

echo "==> joining slices"
mkdir -p "$ROOT/.build/universal"
lipo -create \
    "$ROOT/.build/arm64-apple-macosx/release/VirtualCodexMicro" \
    "$ROOT/.build/x86_64-apple-macosx/release/VirtualCodexMicro" \
    -output "$ROOT/.build/universal/VirtualCodexMicro"
lipo -archs "$ROOT/.build/universal/VirtualCodexMicro"

echo "==> verifying before packaging"
# The arm64 slice, since that is what this machine can execute. The x86_64 slice is
# compiled from identical sources but is NOT exercised here — say so rather than
# imply the universal binary was tested on both.
VCM_SELFTEST=1 "$ROOT/.build/universal/VirtualCodexMicro"

echo "==> bundling"
APP="$(./Scripts/bundle.sh universal)"

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
