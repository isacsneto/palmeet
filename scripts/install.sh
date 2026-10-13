#!/usr/bin/env bash
# Builds (if needed) and installs PalMeet into /Applications, registers the browser connector, and launches it.
#
#   scripts/install.sh            # use build/PalMeet.app if present, else build it
#   scripts/install.sh --rebuild  # always build a fresh Release first
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PalMeet.app"
DEST="/Applications/PalMeet.app"

if pgrep -x PalMeet >/dev/null; then
  echo "PalMeet is running. Quit it first (menu bar icon → power button) so recordings are saved, then re-run." >&2
  exit 1
fi
if [ "${1:-}" = "--rebuild" ] || [ ! -d "$APP" ]; then
  "$ROOT/scripts/build-app.sh" Release
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
"$DEST/Contents/MacOS/PalMeet" --install-connector || echo "(Browser connector not installed: no supported browser found.)"
echo "Installed $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString) to $DEST"
open "$DEST"
