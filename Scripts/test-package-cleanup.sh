#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Exercise the real packaging script with isolated outputs and command mocks.
# In particular, the absolute-path lsregister function prevents any changes to
# the developer's actual Launch Services database.
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kodi-package-cleanup-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/mocks.sh" <<'MOCKS'
uname() { case "$1" in -s) echo Darwin;; -m) echo arm64;; esac; }
security() {
  [[ "$KODI_PACKAGE_TEST_CASE" != preflight-failure ]] || return 1
  if [[ "$1" == cms ]]; then
    local profile=""
    for profile in "$@"; do :; done
    cat "$profile"
  else
    echo '1) mock "Developer ID Application: Emmanuel Onyebueke (3FJF74RW5L)"'
  fi
}
xcodegen() { [[ "$KODI_PACKAGE_TEST_CASE" != project-failure ]]; }
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
  if [[ "$KODI_PACKAGE_TEST_CASE" == built-sync-disabled ]]; then
    cp "$KODI_PACKAGE_TEST_INPUTS/disabled-info.plist" "$KODI_PACKAGE_TEST_APP/Contents/Info.plist"
  elif [[ "$KODI_PACKAGE_TEST_CASE" == built-missing-profile ]]; then
    rm "$KODI_PACKAGE_TEST_APP/Contents/embedded.provisionprofile"
  fi
  touch "$KODI_PACKAGE_TEST_APP/Contents/MacOS/Kodi Reader"
  [[ "$KODI_PACKAGE_TEST_CASE" != build-failure ]]
}
ditto() {
  cp -R "$1" "$2"
  case "$KODI_PACKAGE_TEST_CASE" in
    staged-sync-disabled)
      cp "$KODI_PACKAGE_TEST_INPUTS/disabled-info.plist" "$2/Contents/Info.plist"
      ;;
    staged-missing-profile)
      rm "$2/Contents/embedded.provisionprofile"
      ;;
    staged-unpermitted-profile)
      cp "$KODI_PACKAGE_TEST_INPUTS/unpermitted-profile.plist" "$2/Contents/embedded.provisionprofile"
      ;;
    staged-expired-profile)
      cp "$KODI_PACKAGE_TEST_INPUTS/expired-profile.plist" "$2/Contents/embedded.provisionprofile"
      ;;
  esac
}
otool() { return 0; }
codesign() {
  if [[ "$1" == --display && "$2" == --entitlements ]]; then
    local bundle="" entitlements="$KODI_PACKAGE_TEST_INPUTS/entitlements.plist"
    for bundle in "$@"; do :; done
    printf '%s\n' "$bundle" >> "$KODI_PACKAGE_TEST_SIGNED_LOG"
    if [[ "$KODI_PACKAGE_TEST_CASE" == built-missing-entitlements && "$bundle" == "$KODI_PACKAGE_TEST_APP" ]] ||
      [[ "$KODI_PACKAGE_TEST_CASE" == staged-missing-entitlements && "$bundle" == "$KODI_PACKAGE_STAGING/Kodi Reader.app" ]]; then
      entitlements="$KODI_PACKAGE_TEST_INPUTS/missing-entitlements.plist"
    elif [[ "$KODI_PACKAGE_TEST_CASE" == staged-development-environment && "$bundle" == "$KODI_PACKAGE_STAGING/Kodi Reader.app" ]]; then
      entitlements="$KODI_PACKAGE_TEST_INPUTS/development-entitlements.plist"
    fi
    cat "$entitlements"
  elif [[ "$1" == --display ]]; then
    echo 'Authority=Developer ID Application: Emmanuel Onyebueke (3FJF74RW5L)'
    echo runtime
  elif [[ "$KODI_PACKAGE_TEST_CASE" == signing-failure && "$1" == --force ]]; then
    return 42
  fi
}
hdiutil() {
  [[ "$KODI_PACKAGE_TEST_CASE" != dmg-failure ]] || return 41
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
  [[ "$1" == -u ]] || return 1
  printf '%s\n' "$2" >> "$KODI_PACKAGE_TEST_LOG"
  [[ "$KODI_PACKAGE_TEST_CASE" != unregister-failure ]]
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

for scenario in preflight-failure project-failure build-failure built-sync-disabled built-missing-entitlements built-missing-profile staged-sync-disabled staged-missing-entitlements staged-missing-profile staged-development-environment staged-unpermitted-profile staged-expired-profile dmg-failure signing-failure success compatibility-flag unregister-failure; do
  fixture="$TEST_DIR/$scenario run"
  mkdir -p "$fixture/Scripts" "$fixture/.build"
  cp Scripts/package-dmg.sh "$fixture/Scripts/"
  app="$fixture/derived/Build/Products/Release-iCloud/Kodi Reader.app"
  staging="$fixture/staging"
  mkdir -p "$app/Contents" "$staging/Kodi Reader.app/Contents"
  printf 'preexisting app\n' > "$app/Contents/Info.plist"
  printf 'preexisting staging\n' > "$staging/Kodi Reader.app/Contents/Info.plist"
  printf 'previous successful metadata\n' > "$fixture/.build/release-info.plist"
  log="$fixture/unregistered.log"
  : > "$log"
  config_log="$fixture/build-configurations.log"
  : > "$config_log"
  signed_log="$fixture/entitlement-reads.log"
  : > "$signed_log"
  arguments=()
  if [[ "$scenario" == compatibility-flag ]]; then arguments+=(--icloud); fi
  result=0
  BASH_ENV="$TEST_DIR/mocks.sh" \
    KODI_PACKAGE_TEST_CASE="$scenario" KODI_PACKAGE_TEST_APP="$app" KODI_PACKAGE_TEST_LOG="$log" \
    KODI_PACKAGE_TEST_INPUTS="$TEST_DIR/inputs" KODI_PACKAGE_TEST_CONFIG_LOG="$config_log" \
    KODI_PACKAGE_TEST_SIGNED_LOG="$signed_log" \
    KODI_DERIVED_DATA="$fixture/derived" KODI_PACKAGE_STAGING="$staging" KODI_DMG_PATH="$fixture/KodiReader.dmg" \
    bash "$fixture/Scripts/package-dmg.sh" "${arguments[@]}" > "$fixture/output.log" 2>&1 || result=$?

  python3 - "$scenario" "$fixture" "$app" "$staging" "$log" "$result" <<'PY'
from pathlib import Path
import plistlib
import sys

scenario, fixture, app, staging, log, result = sys.argv[1:]
fixture, app, staging, log = map(Path, (fixture, app, staging, log))
success = scenario in ('success', 'compatibility-flag', 'unregister-failure')
assert (int(result) == 0) == success, (scenario, result, (fixture / 'output.log').read_text())
metadata = fixture / '.build/release-info.plist'
if success:
    assert plistlib.loads(metadata.read_bytes()) == {
        'iCloudSyncEnabled': 'YES', 'CFBundleVersion': 'new release metadata',
    }, scenario
else:
    assert metadata.read_text() == 'previous successful metadata\n', scenario
configurations = (fixture / 'build-configurations.log').read_text().splitlines()
expected_configurations = [] if scenario in ('preflight-failure', 'project-failure') else ['Release-iCloud']
assert configurations == expected_configurations, (scenario, configurations)
signed_reads = [str(Path(path)) for path in (fixture / 'entitlement-reads.log').read_text().splitlines()]
if scenario in ('preflight-failure', 'project-failure', 'build-failure', 'built-sync-disabled', 'built-missing-profile'):
    expected_reads = []
elif scenario in ('built-missing-entitlements', 'staged-sync-disabled', 'staged-missing-profile'):
    expected_reads = [str(app)]
else:
    expected_reads = [str(app), str(staging / 'Kodi Reader.app')]
assert signed_reads == expected_reads, (scenario, signed_reads, (fixture / 'output.log').read_text())
unregistered = [str(Path(path)) for path in log.read_text().splitlines()]
if scenario in ('preflight-failure', 'project-failure'):
    assert (app / 'Contents/Info.plist').read_text() == 'preexisting app\n', scenario
    assert (staging / 'Kodi Reader.app/Contents/Info.plist').read_text() == 'preexisting staging\n', (scenario, (fixture / 'output.log').read_text())
    assert not unregistered, (scenario, unregistered)
elif scenario == 'build-failure' or scenario.startswith('built-'):
    assert not app.exists(), scenario
    assert (staging / 'Kodi Reader.app/Contents/Info.plist').read_text() == 'preexisting staging\n', scenario
    assert unregistered == [str(app)], (scenario, unregistered)
else:
    assert not app.exists() and not staging.exists(), (scenario, (fixture / 'output.log').read_text())
    assert unregistered == [str(app), str(staging / 'Kodi Reader.app')], (scenario, unregistered)
if scenario == 'dmg-failure':
    assert int(result) == 41, result
elif scenario == 'signing-failure':
    assert int(result) == 42, result
if scenario.startswith(('built-', 'staged-')):
    assert not (fixture / 'KodiReader.dmg').exists(), scenario
PY
done
echo "Packaging cleanup and mandatory iCloud release checks passed (17 scenarios)."
