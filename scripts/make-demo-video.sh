#!/usr/bin/env bash
# Renders the README demo (docs/demo.gif and docs/demo.mp4) from the app's real windows, off screen, with
# made-up meetings (Sources/PalMeetCore/DemoContent.swift). Nothing real is recorded; your meetings, settings
# and voices are not touched. The demo instance takes keyboard focus for about a minute while it renders.
#
#   scripts/make-demo-video.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh" Debug
"$ROOT/build/PalMeet.app/Contents/MacOS/PalMeet" --demo-video "$ROOT/docs" >/dev/null 2>&1
ls -lh "$ROOT/docs/demo.gif" "$ROOT/docs/demo.mp4"
echo "Rebuild a Release app before installing: scripts/build-app.sh Release"
