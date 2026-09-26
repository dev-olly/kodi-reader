#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
FRAMEWORK_DIR="${1:-.build/AuthDerivedData/Build/Products/Debug}"
if [[ ! -d "$FRAMEWORK_DIR/Sparkle.framework" ]]; then
  echo "Pass the build products directory containing Sparkle.framework as the first argument."
  exit 1
fi
FRAMEWORK_DIR="$(cd "$FRAMEWORK_DIR" && pwd)"
TEMP_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/kodi-update-tests.XXXXXX")
trap 'rm -rf "$TEMP_BUILD"' EXIT
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/kodi-update-module-cache" \
  -F "$FRAMEWORK_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
  App/AppUpdater.swift Tests/AppTests/UpdateUserDriverTests.swift \
  -o "$TEMP_BUILD/update-tests"
"$TEMP_BUILD/update-tests"
