#!/bin/bash
# Assemble a minimal .app bundle around the SwiftPM binary.
# Needed because TCC (Accessibility, Automation) and Carbon hotkey registration
# identify an app by bundle identity — a bare executable cannot hold either grant.
# No Xcode required: this is just a directory, a plist, and a copy.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/VirtualCodexMicro.app"
BIN="$ROOT/.build/$CONFIG/VirtualCodexMicro"

[ -x "$BIN" ] || { echo "missing $BIN — run: swift build -c $CONFIG" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VirtualCodexMicro"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Virtual Codex Micro</string>
  <key>CFBundleExecutable</key><string>VirtualCodexMicro</string>
  <key>CFBundleIdentifier</key><string>dev.local.virtualcodexmicro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Virtual Codex Micro raises the terminal window that owns an agent session when you click its key.</string>
  <!-- Both speech keys are mandatory, not optional: requesting either
       authorization without its usage string is a hard crash on first press,
       not a declined prompt. Kept in sync with
       SpeechCapture.requiredInfoPlistStrings. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>Virtual Codex Micro records your voice only while you hold the push-to-talk key, so you can dictate a prompt to an agent session.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Virtual Codex Micro transcribes held-key recordings on this Mac to turn them into agent prompts. Speech recognition runs on-device and audio is never sent to Apple.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

# Ad-hoc signature keeps a stable TCC identity across rebuilds during development.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warn: ad-hoc signing failed; TCC grants may reset per build" >&2
echo "$APP"
