#!/usr/bin/env bash
# Release-build Kodi Reader (ad-hoc signed, Apple Silicon) and wrap it in
# KodiReader.dmg. Optional argument is a version tag such as v0.1.0.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "package-dmg.sh must run on macOS" >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "package-dmg.sh requires Apple Silicon" >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null; then
  echo "xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi

VERSION="${1:-}"
VERSION="${VERSION#v}"

APP_NAME="Kodi Reader"
SCHEME="KodiReader"
PROJECT="KodiReader.xcodeproj"
DERIVED="${PWD}/.build/DerivedData"
STAGING="${PWD}/.build/dmg"
OUT="${PWD}/KodiReader.dmg"
APP="${DERIVED}/Build/Products/Release/${APP_NAME}.app"

xcodegen generate

build_app() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    "$@" \
    build
}

if [[ -n "$VERSION" ]]; then
  build_app MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION"
else
  build_app
fi

if [[ ! -d "$APP" ]]; then
  echo "expected app at $APP" >&2
  exit 1
fi

rm -rf "$STAGING" "$OUT"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/${APP_NAME}.app"
# Keep the package artifact self-contained even if Xcode package embedding changes.
FRAMEWORKS="$STAGING/${APP_NAME}.app/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
ditto "$DERIVED/Build/Products/Release/PackageFrameworks/KokoroSwift.framework" \
  "$FRAMEWORKS/KokoroSwift.framework"

# Fail packaging if a linked framework is missing from the distribution.
verify_frameworks() {
  local binary="$1"
  local dependency
  while IFS= read -r dependency; do
    if [[ ! -f "$FRAMEWORKS/${dependency#@rpath/}" ]]; then
      echo "Missing bundled dependency: $dependency (from $binary)" >&2
      exit 1
    fi
  done < <(otool -L "$binary" | awk '$1 ~ /^@rpath\/.*\.framework\// {print $1}')
}
verify_frameworks "$STAGING/${APP_NAME}.app/Contents/MacOS/$APP_NAME"
for framework in "$FRAMEWORKS/"*.framework; do
  name="$(basename "$framework" .framework)"
  verify_frameworks "$framework/$name"
done

# Ad-hoc signing has no Team ID. Release entitlements explicitly disable
# library validation for these bundled libraries.
codesign --force --deep --sign - --options runtime \
  --entitlements App/KodiReader.release.entitlements \
  "$STAGING/${APP_NAME}.app"
codesign --verify --deep --strict "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUT"

echo "wrote $OUT"
