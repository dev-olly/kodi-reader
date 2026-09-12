#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/kodi-note-tests.XXXXXX")
trap 'rm -rf "$TEMP_BUILD"' EXIT
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/kodi-note-module-cache" \
  -target "$(uname -m)-apple-macosx14.0" \
  App/MarkdownTextEditor.swift Tests/AppTests/RichNoteEditorTests.swift \
  -o "$TEMP_BUILD/note-editor-tests"
"$TEMP_BUILD/note-editor-tests"
