#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kodi-highlight-popover-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -module-cache-path "$TEST_DIR/modules" \
  -target "$(uname -m)-apple-macosx14.0" \
  App/HighlightPopoverLayout.swift Tests/AppTests/HighlightPopoverLayoutTests.swift \
  -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
