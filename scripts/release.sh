#!/usr/bin/env bash
# Publishes a new PalMeet version for in-app updates (Sparkle).
#
#   scripts/release.sh 0.2.0 [release-notes.md]
#
# 1. Sets VERSION, builds and signs the Release app.
# 2. Zips it into the `releases` branch (checked out at build/releases), keeping the 3 newest versions.
# 3. Runs Sparkle's generate_appcast: EdDSA-signs each archive with the key in your Keychain (account
#    "palmeet") and writes appcast.xml, the feed the app reads (Info.plist SUFeedURL).
# 4. Commits + pushes the releases branch, tags the source (vX.Y.Z) and pushes the tag.
# Set PALMEET_NO_PUSH=1 to prepare everything locally without pushing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?usage: scripts/release.sh <version> [notes.md]}"
NOTES="${2:-}"
REPO_RAW="https://raw.githubusercontent.com/isacsneto/palmeet/releases/"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
RELEASES="$ROOT/build/releases"

[ -x "$SPARKLE_BIN/generate_appcast" ] || swift package resolve >/dev/null
if [ -n "$(git status --porcelain -- Sources Resources Package.swift App VERSION 2>/dev/null)" ]; then
  echo "Commit your source changes before releasing (the release is tagged from HEAD)." >&2
  exit 1
fi

# The releases branch lives in its own worktree.
git fetch origin releases 2>/dev/null || true
if [ ! -d "$RELEASES/.git" ] && [ ! -f "$RELEASES/.git" ]; then
  rm -rf "$RELEASES"
  if git show-ref --verify --quiet refs/remotes/origin/releases; then
    git worktree add "$RELEASES" -B releases origin/releases >/dev/null
  else
    git worktree add --detach "$RELEASES" >/dev/null
    (cd "$RELEASES" && git checkout --orphan releases >/dev/null && git rm -rf --quiet . && \
      printf '# PalMeet releases\n\nSigned builds and the Sparkle appcast for in-app updates. Install from the newest zip or use the app\x27s updater.\n' > README.md)
  fi
else
  (cd "$RELEASES" && git pull --quiet --ff-only origin releases 2>/dev/null || true)
fi

echo "$VERSION" > VERSION
git add VERSION
git commit --quiet -m "Release $VERSION" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -- VERSION || true
"$ROOT/scripts/build-app.sh" Release

ARCHIVE="$RELEASES/PalMeet-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/PalMeet.app" "$ARCHIVE"
if [ -n "$NOTES" ]; then
  { echo "<h2>PalMeet $VERSION</h2><ul>"; sed -E 's/^[-*] +//; /^$/d; s/&/\&amp;/g; s/</\&lt;/g; s/^/<li>/; s/$/<\/li>/' "$NOTES"; echo "</ul>"; } > "$RELEASES/PalMeet-$VERSION.html"
fi

# Keep the three newest archives (Sparkle only needs the latest; older ones allow rollback).
ls -t "$RELEASES"/PalMeet-*.zip | tail -n +4 | while read -r old; do rm -f "$old" "${old%.zip}.html"; done

"$SPARKLE_BIN/generate_appcast" --account palmeet --download-url-prefix "$REPO_RAW" \
  --maximum-deltas 0 --embed-release-notes -o "$RELEASES/appcast.xml" "$RELEASES"
"$SPARKLE_BIN/sign_update" --account palmeet --verify "$ARCHIVE" \
  "$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$RELEASES/appcast.xml" | head -1)" >/dev/null && echo "Signature verified."

(cd "$RELEASES" && git add -A && git commit --quiet -m "PalMeet $VERSION" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")
git tag -f "v$VERSION" >/dev/null
if [ -z "${PALMEET_NO_PUSH:-}" ]; then
  (cd "$RELEASES" && git push --quiet origin releases)
  git push --quiet origin HEAD "v$VERSION"
  echo "Published PalMeet $VERSION. Installed apps will offer it on their next check (or Check for Updates…)."
else
  echo "Prepared PalMeet $VERSION in $RELEASES (not pushed)."
fi
