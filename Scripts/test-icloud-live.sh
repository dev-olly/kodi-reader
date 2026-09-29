#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
derived_data="$repo_root/.build/CloudKitSmokeDerivedData"
app="$derived_data/Build/Products/Debug-iCloud/Kodi CloudKit Smoke.app"
verification="$repo_root/.build/CloudKitSmokeVerification"
mkdir -p "$verification"

cat <<'NOTICE'
This tests the REAL iCloud Development database using synthetic data and two
isolated local stores. It never opens Kodi Reader's existing local library.
A successful run deletes its own synthetic book and assets, leaving tombstones.
An interrupted or failed run retains its fixture and local report for diagnosis.
This is a one-Mac smoke test; two physical Macs must still be tested before release.
NOTICE

xcodegen generate
xcodebuild -project KodiReader.xcodeproj -scheme KodiReader-SyncSmoke \
  -configuration Debug-iCloud -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration build

codesign --verify --deep --strict "$app"
codesign --display --entitlements - --xml "$app" > "$verification/entitlements.plist" 2> "$verification/signature.log"
security cms -D -i "$app/Contents/embedded.provisionprofile" > "$verification/profile.plist"

python3 - "$verification" <<'PY'
import datetime
import pathlib
import plistlib
import sys

root = pathlib.Path(sys.argv[1])
entitlements = plistlib.loads((root / 'entitlements.plist').read_bytes())
profile = plistlib.loads((root / 'profile.plist').read_bytes())
assert entitlements.get('com.apple.developer.team-identifier') == '3FJF74RW5L', 'Wrong signing team'
assert entitlements.get('com.apple.application-identifier') == '3FJF74RW5L.com.olly.KodiReader', 'Wrong app identifier'
assert entitlements.get('com.apple.developer.icloud-container-environment') == 'Development', 'Refusing to test Production'
assert 'iCloud.com.olly.KodiReader' in entitlements.get('com.apple.developer.icloud-container-identifiers', []), 'Missing container'
assert 'iCloud.com.olly.KodiReader' in entitlements.get('com.apple.developer.icloud-container-development-container-identifiers', []), 'Missing Development container'
assert 'CloudKit' in entitlements.get('com.apple.developer.icloud-services', []), 'Missing CloudKit service'
assert entitlements.get('com.apple.developer.aps-environment') == 'development', 'Wrong push environment'
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired provisioning profile'
allowed = profile['Entitlements']
assert allowed.get('com.apple.application-identifier') == entitlements['com.apple.application-identifier'], 'Profile app ID mismatch'
assert 'iCloud.com.olly.KodiReader' in allowed.get('com.apple.developer.icloud-container-identifiers', []), 'Profile lacks container'
assert 'iCloud.com.olly.KodiReader' in allowed.get('com.apple.developer.icloud-container-development-container-identifiers', []), 'Profile lacks Development container'
services = allowed.get('com.apple.developer.icloud-services', [])
assert services == '*' or 'CloudKit' in services, 'Profile lacks CloudKit'
print('Verified signed Development configuration and provisioning profile.')
PY

"$app/Contents/MacOS/Kodi CloudKit Smoke" | tee "$verification/run.log"
