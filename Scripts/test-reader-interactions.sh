#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
KODI_INTERACTION_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/kodi-interaction-tests.XXXXXX")
trap 'rm -rf "$KODI_INTERACTION_BUILD"' EXIT
KODI_CORE_BUILD=".build/$(uname -m)-apple-macosx/debug"
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/kodi-note-module-cache" \
  -target "$(uname -m)-apple-macosx14.0" -I "$KODI_CORE_BUILD/Modules" \
  "$KODI_CORE_BUILD"/EpubKit.build/*.swift.o \
  "$KODI_CORE_BUILD"/ReaderUI.build/*.swift.o \
  "$KODI_CORE_BUILD"/ZIPFoundation.build/*.swift.o \
  App/HighlightPalette.swift App/ReaderWorkspacePresentation.swift \
  Tests/AppTests/ReaderInteractionTests.swift -o "$KODI_INTERACTION_BUILD/reader-interaction-tests"
"$KODI_INTERACTION_BUILD/reader-interaction-tests"
