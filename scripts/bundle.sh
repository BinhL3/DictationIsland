#!/usr/bin/env bash
# Builds build/DictationIsland.app: release binary, icon, Info.plist, stable signature.
# Microphone and Speech permissions need a real bundle with usage strings; a bare SwiftPM
# executable is killed by TCC on first mic access.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DictationIsland"

APP="build/DictationIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DictationIsland"

# Icon (regenerated only when the script changes).
if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset >/dev/null
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DictationIsland</string>
    <key>CFBundleIdentifier</key><string>dev.voicedictation.DictationIsland</string>
    <key>CFBundleName</key><string>DictationIsland</string>
    <key>CFBundleDisplayName</key><string>DictationIsland</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>DictationIsland listens while you hold the dictation key.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>DictationIsland turns your speech into text.</string>
    <key>NSAudioCaptureUsageDescription</key><string>DictationIsland muffles music and videos while you dictate.</string>
</dict>
</plist>
PLIST

# Stable local identity keeps permission grants across rebuilds; fall back to ad-hoc.
if IDENTITY="$(scripts/signing.sh 2>/dev/null)" && [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --keychain "$HOME/Library/Keychains/dictationisland-signing.keychain-db" "$APP"
  echo "Signed with DictationIsland Local Signing"
else
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc (permissions may reset after each rebuild)"
fi
echo "Built $APP ($VERSION)"
