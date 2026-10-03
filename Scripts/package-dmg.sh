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
ICLOUD=0
GOOGLE_DRIVE=0
for argument in "$@"; do
  case "$argument" in
    --icloud)
      ICLOUD=1
      ;;
    --notarize)
      NOTARIZE=1
      ;;
    --google-drive)
      GOOGLE_DRIVE=1
      ;;
    -h|--help)
      echo "usage: $0 [version] [--notarize] [--icloud] [--google-drive]"
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

BUILD_CONFIGURATION="Release"
if [[ "$ICLOUD" == 1 ]]; then
  BUILD_CONFIGURATION="Release-iCloud"
fi
APP_NAME="Kodi Reader"
SCHEME="KodiReader"
PROJECT="KodiReader.xcodeproj"
DERIVED="${KODI_DERIVED_DATA:-${PWD}/.build/DerivedData}"
STAGING="${KODI_PACKAGE_STAGING:-${PWD}/.build/dmg}"
OUT="${KODI_DMG_PATH:-${PWD}/KodiReader.dmg}"
APP="${DERIVED}/Build/Products/${BUILD_CONFIGURATION}/${APP_NAME}.app"
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
    -configuration "$BUILD_CONFIGURATION" \
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
  # Build numbers must keep increasing for Sparkle, independently of the
  # user-visible version. CURRENT_PROJECT_VERSION comes from project.yml.
  build_app MARKETING_VERSION="$VERSION"
else
  build_app
fi

if [[ ! -d "$APP" ]]; then
  echo "expected app at $APP" >&2
  exit 1
fi

if [[ "$GOOGLE_DRIVE" == 1 ]]; then
  DRIVE_CLIENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :GoogleDriveClientID' "$APP/Contents/Info.plist")"
  if [[ ! "$DRIVE_CLIENT_ID" =~ ^[A-Za-z0-9._-]+\.apps\.googleusercontent\.com$ ]] || [[ "$DRIVE_CLIENT_ID" == YOUR_CLIENT_ID* ]]; then
    echo "Google Drive release requires a configured Desktop OAuth client ID in the final app." >&2
    exit 1
  fi
fi

if [[ "$ICLOUD" == 1 ]]; then
  if [[ ! -f "$APP/Contents/embedded.provisionprofile" ]]; then
    echo "iCloud builds require an embedded Developer ID provisioning profile." >&2
    exit 1
  fi
  codesign --display --entitlements - --xml "$APP" > "$DERIVED/icloud-entitlements.plist" 2>/dev/null
  /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "$DERIVED/icloud-entitlements.plist" | grep -Fxq 'iCloud.com.olly.KodiReader'
  security cms -D -i "$APP/Contents/embedded.provisionprofile" > "$DERIVED/icloud-profile.plist"
  python3 - "$DERIVED/icloud-entitlements.plist" "$DERIVED/icloud-profile.plist" "$TEAM_ID" <<'PY'
import datetime
import plistlib
import sys

with open(sys.argv[1], 'rb') as file:
    signed = plistlib.load(file)
with open(sys.argv[2], 'rb') as file:
    profile = plistlib.load(file)
permitted = profile['Entitlements']
expected = {
    'com.apple.application-identifier': sys.argv[3] + '.com.olly.KodiReader',
    'com.apple.developer.team-identifier': sys.argv[3],
    'com.apple.developer.icloud-container-environment': 'Production',
    'com.apple.developer.aps-environment': 'production',
}
for key, value in expected.items():
    if signed.get(key) != value:
        sys.exit('Incorrect distribution entitlement: ' + key)
    allowance = permitted.get(key)
    if allowance != value and not (isinstance(allowance, list) and value in allowance):
        sys.exit('Provisioning profile does not permit: ' + key)
for key, value in {
    'com.apple.developer.icloud-services': 'CloudKit',
    'com.apple.developer.icloud-container-identifiers': 'iCloud.com.olly.KodiReader',
}.items():
    allowance = permitted.get(key, [])
    if value not in signed.get(key, []) or (allowance != '*' and value not in allowance):
        sys.exit('Missing container/service permission: ' + key)
expiry = profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
if expiry <= datetime.datetime.now(datetime.timezone.utc):
    sys.exit('The Developer ID provisioning profile has expired.')
PY
fi

# A build (unlike archive/export) does not re-sign Sparkle's nested helpers.
# Sign from the inside out so every executable has our Developer ID and timestamp.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  for helper in XPCServices/Installer.xpc Autoupdate Updater.app; do
    codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" \
      "$SPARKLE/Versions/B/$helper"
  done
  codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
    --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$SPARKLE"
  codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" \
    --preserve-metadata=entitlements "$APP"
fi

rm -rf "$STAGING" "$OUT"
mkdir -p "$STAGING" "$(dirname "$OUT")"
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
