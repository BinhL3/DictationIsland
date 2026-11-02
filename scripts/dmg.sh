#!/usr/bin/env bash
# Builds build/DictationIsland-<version>.dmg with the app and an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh release

VERSION="$(cat VERSION)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/DictationIsland.app "$STAGE/DictationIsland.app"
ln -s /Applications "$STAGE/Applications"

DMG="build/DictationIsland-$VERSION.dmg"
rm -f "$DMG"
# HFS+ explicitly: newer macOS defaults to an APFS image that older hdiutil/macOS 26 can reject.
hdiutil create -volname "DictationIsland $VERSION" -srcfolder "$STAGE" -fs HFS+ -ov -format UDZO "$DMG" >/dev/null 2>&1
echo "Built $DMG"
