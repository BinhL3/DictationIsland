#!/usr/bin/env bash
# Builds build/DictationIsland-<version>.dmg with the app and an Applications shortcut.
#
# With a Developer ID certificate in the keychain it also notarizes: the app first (and staples
# its ticket, so it opens offline once copied out), then the signed DMG. Notarization uses the
# notarytool keychain profile "DictationIsland" (NOTARY_PROFILE to change it), made once with:
#   xcrun notarytool store-credentials DictationIsland --apple-id <Apple ID> --team-id <team ID>
# NOTARIZE=0 skips it.
set -euo pipefail
cd "$(dirname "$0")/.."
TIMESTAMP=1 scripts/bundle.sh release

VERSION="$(cat VERSION)"
APP=build/DictationIsland.app
PROFILE="${NOTARY_PROFILE:-DictationIsland}"
DEVELOPER_ID="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p')"
NOTARIZE="${NOTARIZE:-1}"
[[ -n "$DEVELOPER_ID" ]] || NOTARIZE=0

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

notarize() {  # file
  echo "Notarizing $(basename "$1")…"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m | tee "$STAGE/notary.log"
  grep -q "status: Accepted" "$STAGE/notary.log" || {
    ID="$(sed -n 's/^  id: //p' "$STAGE/notary.log" | head -1)"
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
    echo "Notarization failed" >&2; exit 1
  }
}

if [[ "$NOTARIZE" == 1 ]]; then
  ditto -c -k --keepParent "$APP" "$STAGE/app.zip"
  notarize "$STAGE/app.zip"
  xcrun stapler staple "$APP"
fi

mkdir "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/DictationIsland.app"
ln -s /Applications "$STAGE/dmg/Applications"

DMG="build/DictationIsland-$VERSION.dmg"
rm -f "$DMG"
# HFS+ explicitly: newer macOS defaults to an APFS image that older hdiutil/macOS 26 can reject.
hdiutil create -volname "DictationIsland $VERSION" -srcfolder "$STAGE/dmg" -fs HFS+ -ov -format UDZO "$DMG" >/dev/null 2>&1

if [[ "$NOTARIZE" == 1 ]]; then
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  echo "Built $DMG (notarized)"
else
  echo "Built $DMG (not notarized)"
fi
