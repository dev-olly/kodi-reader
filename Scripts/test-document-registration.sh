#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kodi-registration-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
for enabled in 0 1; do
  xcrun clang -E -P -traditional -x c -DKODI_DOCUMENT_HANDLERS="$enabled" App/Info.plist -o "$TEST_DIR/$enabled.plist"
done
python3 - "$TEST_DIR" <<'PY'
import plistlib, sys
for enabled in (0, 1):
    with open(sys.argv[1] + '/' + str(enabled) + '.plist', 'rb') as source:
        info = plistlib.load(source)
    assert ('CFBundleDocumentTypes' in info) == bool(enabled)
    assert info['SUFeedURL'].startswith('https://')
PY
xcrun swiftc -module-cache-path "$TEST_DIR/modules" App/DocumentRegistration.swift \
  Tests/AppTests/DocumentRegistrationTests.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
