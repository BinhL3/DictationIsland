#!/usr/bin/env bash
# Builds and installs DictationIsland into /Applications (or ~/Applications), then relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh release

DEST_DIR="/Applications"
[[ -w "$DEST_DIR" ]] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/DictationIsland.app"

pkill -x DictationIsland 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST"
ditto build/DictationIsland.app "$DEST"
# Otherwise Launch Services may open the build/ copy instead, and two copies end up running.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u build/DictationIsland.app 2>/dev/null || true
open "$DEST"
echo "Installed $DEST"
