#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Exercise the real packaging script without Xcode, signing keys, or cloud access.
# Every output is isolated, and Launch Services registration is mocked as well.
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kodi-package-icloud-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/mocks.sh" <<'MOCKS'
uname() { case "$1" in -s) echo Darwin;; -m) echo arm64;; esac; }
security() {
  if [[ "$1" == cms ]]; then
    local profile=""
    for profile in "$@"; do :; done
    cat "$profile"
  else
    echo '1) mock "Developer ID Application: Emmanuel Onyebueke (3FJF74RW5L)"'
  fi
}
xcodegen() { return 0; }
corrupt_bundle() {
  local phase="$1" bundle="$2" fault
  [[ "$KODI_PACKAGE_TEST_CASE" == "$phase-"* ]] || return 0
  fault="${KODI_PACKAGE_TEST_CASE#"$phase-"}"
  case "$fault" in
    sync-disabled)
      cp "$KODI_PACKAGE_TEST_INPUTS/disabled-info.plist" "$bundle/Contents/Info.plist"
      ;;
    missing-sync-flag)
      cp "$KODI_PACKAGE_TEST_INPUTS/missing-flag-info.plist" "$bundle/Contents/Info.plist"
      ;;
    missing-profile)
      rm "$bundle/Contents/embedded.provisionprofile"
      ;;
    unpermitted-profile|expired-profile)
      cp "$KODI_PACKAGE_TEST_INPUTS/$fault.plist" "$bundle/Contents/embedded.provisionprofile"
      ;;
  esac
}
xcodebuild() {
  local previous="" argument
  for argument in "$@"; do
    if [[ "$previous" == -configuration ]]; then
      printf '%s\n' "$argument" >> "$KODI_PACKAGE_TEST_CONFIG_LOG"
    fi
    previous="$argument"
  done
  mkdir -p "$KODI_PACKAGE_TEST_APP/Contents/MacOS"
  cp "$KODI_PACKAGE_TEST_INPUTS/Info.plist" "$KODI_PACKAGE_TEST_APP/Contents/Info.plist"
  cp "$KODI_PACKAGE_TEST_INPUTS/profile.plist" "$KODI_PACKAGE_TEST_APP/Contents/embedded.provisionprofile"
  touch "$KODI_PACKAGE_TEST_APP/Contents/MacOS/Kodi Reader"
  corrupt_bundle built "$KODI_PACKAGE_TEST_APP"
}
ditto() {
  cp -R "$1" "$2"
  corrupt_bundle staged "$2"
}
otool() { return 0; }
codesign() {
  if [[ "$1" == --display && "$2" == --entitlements ]]; then
    local bundle="" phase=built entitlements="$KODI_PACKAGE_TEST_INPUTS/entitlements.plist"
    for bundle in "$@"; do :; done
    printf '%s\n' "$bundle" >> "$KODI_PACKAGE_TEST_SIGNED_LOG"
    if [[ "$bundle" == "$KODI_PACKAGE_STAGING/Kodi Reader.app" ]]; then phase=staged; fi
    case "$KODI_PACKAGE_TEST_CASE" in
      "$phase-missing-entitlements") entitlements="$KODI_PACKAGE_TEST_INPUTS/missing-entitlements.plist";;
      "$phase-development-environment") entitlements="$KODI_PACKAGE_TEST_INPUTS/development-entitlements.plist";;
    esac
    cat "$entitlements"
  elif [[ "$1" == --display ]]; then
    echo 'Authority=Developer ID Application: Emmanuel Onyebueke (3FJF74RW5L)'
    echo runtime
  fi
}
hdiutil() {
  [[ "$1" == create ]] || return 1
  local output=""
  for output in "$@"; do :; done
  touch "$output"
}
function /usr/libexec/PlistBuddy() {
  python3 - "$@" <<'PY'
import plistlib
import sys

try:
    with open(sys.argv[3], 'rb') as file:
        value = plistlib.load(file)
    command = sys.argv[2]
    assert command.startswith('Print :')
    for key in command[len('Print :'):].split(':'):
        value = value[int(key)] if isinstance(value, list) else value[key]
    print(value)
except (KeyError, IndexError, ValueError):
    sys.exit(1)
PY
}
function /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister() {
  return 0
}
MOCKS

mkdir "$TEST_DIR/inputs"
python3 - "$TEST_DIR/inputs" <<'PY'
import datetime
from pathlib import Path
import plistlib
import sys

inputs = Path(sys.argv[1])

def save(name, value):
    with (inputs / name).open('wb') as file:
        plistlib.dump(value, file)

save('Info.plist', {'iCloudSyncEnabled': 'YES', 'CFBundleVersion': 'new release metadata'})
save('disabled-info.plist', {'iCloudSyncEnabled': 'NO', 'CFBundleVersion': 'new release metadata'})
save('missing-flag-info.plist', {'CFBundleVersion': 'new release metadata'})
entitlements = {
    'com.apple.application-identifier': '3FJF74RW5L.com.olly.KodiReader',
    'com.apple.developer.team-identifier': '3FJF74RW5L',
    'com.apple.developer.icloud-container-environment': 'Production',
    'com.apple.developer.aps-environment': 'production',
    'com.apple.developer.icloud-services': ['CloudKit'],
    'com.apple.developer.icloud-container-identifiers': ['iCloud.com.olly.KodiReader'],
}
save('entitlements.plist', entitlements)
save('missing-entitlements.plist', {})
save('development-entitlements.plist', dict(entitlements, **{
    'com.apple.developer.icloud-container-environment': 'Development',
    'com.apple.developer.aps-environment': 'development',
}))
profile = {
    'Entitlements': entitlements,
    'ExpirationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=30),
}
save('profile.plist', profile)
save('unpermitted-profile.plist', dict(profile, Entitlements={}))
save('expired-profile.plist', dict(profile, ExpirationDate=datetime.datetime(2000, 1, 1)))
PY

scenarios=(success compatibility-flag)
for phase in built staged; do
  for fault in sync-disabled missing-sync-flag missing-entitlements missing-profile development-environment unpermitted-profile expired-profile; do
    scenarios+=("$phase-$fault")
  done
done
for scenario in "${scenarios[@]}"; do
  fixture="$TEST_DIR/$scenario run"
  mkdir -p "$fixture/Scripts"
  cp Scripts/package-dmg.sh "$fixture/Scripts/"
  app="$fixture/derived/Build/Products/Release-iCloud/Kodi Reader.app"
  staging="$fixture/staging"
  config_log="$fixture/build-configurations.log"
  signed_log="$fixture/entitlement-reads.log"
  : > "$config_log"
  : > "$signed_log"
  arguments=()
  if [[ "$scenario" == compatibility-flag ]]; then arguments+=(--icloud); fi
  result=0
  BASH_ENV="$TEST_DIR/mocks.sh" \
    KODI_PACKAGE_TEST_CASE="$scenario" KODI_PACKAGE_TEST_APP="$app" \
    KODI_PACKAGE_TEST_INPUTS="$TEST_DIR/inputs" KODI_PACKAGE_TEST_CONFIG_LOG="$config_log" \
    KODI_PACKAGE_TEST_SIGNED_LOG="$signed_log" \
    KODI_DERIVED_DATA="$fixture/derived" KODI_PACKAGE_STAGING="$staging" KODI_DMG_PATH="$fixture/KodiReader.dmg" \
    bash "$fixture/Scripts/package-dmg.sh" "${arguments[@]}" > "$fixture/output.log" 2>&1 || result=$?

  python3 - "$scenario" "$fixture" "$app" "$staging" "$result" <<'PY'
from pathlib import Path
import plistlib
import sys

scenario, fixture, app, staging, result = sys.argv[1:]
fixture, app, staging = map(Path, (fixture, app, staging))
output = (fixture / 'output.log').read_text()
success = scenario in ('success', 'compatibility-flag')
assert (int(result) == 0) == success, (scenario, result, output)
configurations = (fixture / 'build-configurations.log').read_text().splitlines()
assert configurations == ['Release-iCloud'], (scenario, configurations, output)
signed_reads = [str(Path(path)) for path in (fixture / 'entitlement-reads.log').read_text().splitlines()]
fault = scenario.split('-', 1)[1] if not success else None
if scenario.startswith('built-') and fault in ('sync-disabled', 'missing-sync-flag', 'missing-profile'):
    expected_reads = []
elif scenario.startswith('built-') or fault in ('sync-disabled', 'missing-sync-flag', 'missing-profile'):
    expected_reads = [str(app)]
else:
    expected_reads = [str(app), str(staging / 'Kodi Reader.app')]
assert signed_reads == expected_reads, (scenario, signed_reads, output)
if success:
    assert (fixture / 'KodiReader.dmg').is_file(), scenario
    metadata = fixture / '.build/release-info.plist'
    assert plistlib.loads(metadata.read_bytes()) == {
        'iCloudSyncEnabled': 'YES', 'CFBundleVersion': 'new release metadata',
    }, scenario
else:
    assert not (fixture / 'KodiReader.dmg').exists(), scenario
PY
done
echo "Mandatory iCloud packaging checks passed (${#scenarios[@]} scenarios)."
