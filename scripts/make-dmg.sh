#!/usr/bin/env bash
# Packages build/PalMeet.app as a drag-to-install disk image: build/PalMeet-<version>.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PalMeet.app"
[ -d "$APP" ] || "$ROOT/scripts/build-app.sh" Release
VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/PalMeet.app"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/build/PalMeet-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "PalMeet $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Created $DMG"
