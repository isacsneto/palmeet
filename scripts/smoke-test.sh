#!/usr/bin/env bash
# Launches an app bundle and checks that it is actually idle afterwards (not just running): a main-thread loop
# shows up as sustained CPU or growing memory.
#   scripts/smoke-test.sh [path/to/PalMeet.app]   (default: build/PalMeet.app)
set -euo pipefail
APP="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/PalMeet.app}"
BIN="$APP/Contents/MacOS/PalMeet"
pgrep -f "$BIN" >/dev/null && { echo "Quit the running copy of $APP first." >&2; exit 1; }
open "$APP"
sleep 15
PID="$(pgrep -f "$BIN" | head -1)"
[ -n "$PID" ] || { echo "FAIL: app is not running (crashed at launch?)"; exit 1; }
read -r _ RSS1 <<<"$(ps -o %cpu=,rss= -p "$PID")"
MAXCPU=0
for _ in 1 2 3 4 5; do
  CPU="$(ps -o %cpu= -p "$PID" | tr -d ' ')"
  MAXCPU="$(echo "$CPU $MAXCPU" | awk '{print ($1>$2)?$1:$2}')"
  sleep 2
done
RSS2="$(ps -o rss= -p "$PID" | tr -d ' ')"
kill -TERM "$PID" 2>/dev/null || true
echo "max CPU ${MAXCPU}%, memory ${RSS1} KB → ${RSS2} KB"
awk -v c="$MAXCPU" -v a="$RSS1" -v b="$RSS2" 'BEGIN { exit !(c < 15 && b < a * 1.5 + 20000) }' \
  && echo "PASS: idle after launch" || { echo "FAIL: not idle (busy loop or runaway memory)"; exit 1; }
