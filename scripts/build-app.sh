#!/usr/bin/env bash
# Builds build/PalMeet.app with Xcode (App/PalMeet.xcodeproj) and signs it.
#
#   scripts/build-app.sh [Release|Debug]
#
# Version: VERSION file (marketing version); build number: $PALMEET_BUILD_NUMBER or a yymmddHHMM timestamp
# (must only increase: Sparkle compares build numbers).
# Signing: $PALMEET_SIGN_IDENTITY, else "PalMeet Development" if that identity exists (scripts/create-dev-cert.sh),
# else ad-hoc. A stable identity keeps macOS privacy permissions and lets Sparkle accept updates.
set -euo pipefail

CONFIG="${1:-Release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="${PALMEET_BUILD_NUMBER:-$(date +%y%m%d%H%M)}"
DERIVED="$ROOT/build/DerivedData"
APP="$ROOT/build/PalMeet.app"
ENTITLEMENTS="$ROOT/Resources/PalMeet.entitlements"

if [ ! -d App/PalMeet.xcodeproj ] || [ App/project.yml -nt App/PalMeet.xcodeproj/project.pbxproj ]; then
  (cd App && xcodegen generate --spec project.yml >/dev/null)
fi

echo "Building PalMeet ${VERSION} (${BUILD}), ${CONFIG}…"
xcodebuild -project App/PalMeet.xcodeproj -scheme PalMeet -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -quiet build

rm -rf "$APP"
mkdir -p "$ROOT/build"
ditto "$DERIVED/Build/Products/$CONFIG/PalMeet.app" "$APP"

IDENTITY="${PALMEET_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"PalMeet Development"'; then
  IDENTITY="PalMeet Development"
fi
IDENTITY="${IDENTITY:--}"

# Sign inside-out: Sparkle's helpers, the framework, resource bundles, then the app (hardened runtime throughout).
sign() { codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
    [ -e "$xpc" ] && sign --preserve-metadata=entitlements "$xpc"
  done
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
fi
for bundle in "$APP"/Contents/Resources/*.bundle; do
  [ -e "$bundle" ] && sign "$bundle"
done
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP — PalMeet $VERSION ($BUILD), signed with: $IDENTITY"
