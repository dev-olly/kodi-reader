#!/usr/bin/env bash
# Run after notarizing the release DMG. Publish the GitHub asset before pushing
# appcast.xml so installed apps never see an update that cannot be downloaded.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=".build/dmg/Kodi Reader.app"
TOOLS=".build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
ACCOUNT="${KODI_SPARKLE_ACCOUNT:-com.olly.KodiReader}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
ARCHIVES=".build/updates/$VERSION"

if [[ "$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)" != "$PUBLIC_KEY" ]]; then
  echo "The update-signing key does not match this app's public key." >&2
  exit 1
fi
xcrun stapler validate KodiReader.dmg
spctl --assess --type open --context context:primary-signature KodiReader.dmg

mkdir -p "$ARCHIVES"
cp KodiReader.dmg "$ARCHIVES/KodiReader.dmg"
cp "docs/releases/$VERSION.md" "$ARCHIVES/KodiReader.md"
if [[ -f appcast.xml ]]; then cp appcast.xml "$ARCHIVES/appcast.xml"; fi

"$TOOLS/generate_appcast" --account "$ACCOUNT" \
  --download-url-prefix "https://github.com/dev-olly/kodi-reader/releases/download/v$VERSION/" \
  --link "https://www.kodi-reader.app" \
  --embed-release-notes --maximum-deltas 0 "$ARCHIVES"
cp "$ARCHIVES/appcast.xml" appcast.xml
echo "Generated signed appcast.xml for Kodi Reader $VERSION. Publish the DMG before pushing the feed."
