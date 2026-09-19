#!/usr/bin/env bash
# Release-build Kodi Reader, sign it with Developer ID, and wrap it in a DMG.
# Pass --notarize to submit the final DMG to Apple and staple the ticket.
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

VERSION=""
NOTARIZE=0
for argument in "$@"; do
  case "$argument" in
    --notarize)
      NOTARIZE=1
      ;;
    -h|--help)
      echo "usage: $0 [version] [--notarize]"
      echo "example: $0 0.1.0 --notarize"
      exit 0
      ;;
    -*)
      echo "unknown option: $argument" >&2
      exit 2
      ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "only one version may be supplied" >&2
        exit 2
      fi
      VERSION="${argument#v}"
      ;;
  esac
done

APP_NAME="Kodi Reader"
SCHEME="KodiReader"
PROJECT="KodiReader.xcodeproj"
DERIVED="${PWD}/.build/DerivedData"
STAGING="${PWD}/.build/dmg"
OUT="${PWD}/KodiReader.dmg"
APP="${DERIVED}/Build/Products/Release/${APP_NAME}.app"
TEAM_ID="${KODI_TEAM_ID:-3FJF74RW5L}"
SIGNING_IDENTITY="${KODI_SIGNING_IDENTITY:-Developer ID Application: Emmanuel Onyebueke (3FJF74RW5L)}"
NOTARY_PROFILE="${KODI_NOTARY_PROFILE:-KodiReaderNotary}"

if ! security find-identity -v -p codesigning | grep -Fq "\"${SIGNING_IDENTITY}\""; then
  echo "Developer ID signing identity not found in the login keychain:" >&2
  echo "  ${SIGNING_IDENTITY}" >&2
  echo "Install the certificate and its private key before packaging." >&2
  exit 1
fi

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
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
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
FRAMEWORKS="$STAGING/${APP_NAME}.app/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

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
  [[ -d "$framework" ]] || continue
  name="$(basename "$framework" .framework)"
  verify_frameworks "$framework/$name"
done

codesign --verify --deep --strict --verbose=2 "$STAGING/${APP_NAME}.app"
SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$STAGING/${APP_NAME}.app" 2>&1)"
if [[ "$SIGNATURE_DETAILS" != *"Authority=${SIGNING_IDENTITY}"* ]]; then
  echo "Release app was not signed by the expected Developer ID identity." >&2
  exit 1
fi
if [[ "$SIGNATURE_DETAILS" != *"runtime"* ]]; then
  echo "Release app does not have Hardened Runtime enabled." >&2
  exit 1
fi
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUT"

codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$OUT"
codesign --verify --verbose=2 "$OUT"

if [[ "$NOTARIZE" -eq 1 ]]; then
  xcrun notarytool submit "$OUT" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$OUT"
  xcrun stapler validate "$OUT"
  spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$OUT"
  echo "wrote signed and notarized $OUT"
else
  echo "wrote signed but NOT NOTARIZED $OUT"
  echo "Do not publish this DMG. Configure notary credentials and rerun with --notarize." >&2
fi
