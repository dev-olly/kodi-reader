#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TRANSCRIPTION_TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/kodi-transcription-tests.XXXXXX")
trap 'rm -rf "$TRANSCRIPTION_TEST_BUILD"' EXIT
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/kodi-note-module-cache" \
  -target "$(uname -m)-apple-macosx15.0" \
  App/Audio/AudioTranscriptionController.swift Tests/AppTests/AudioTranscriptionTests.swift \
  -o "$TRANSCRIPTION_TEST_BUILD/transcription-tests"
if [[ "${1:-}" == "--native" ]]; then
  # File synthesis is silent and uses no input device or user audio.
  /usr/bin/say -v Samantha -o "$TRANSCRIPTION_TEST_BUILD/fixture.aiff" \
    "This book gave me a new idea. I want to remember this passage."
  "$TRANSCRIPTION_TEST_BUILD/transcription-tests" --native "$TRANSCRIPTION_TEST_BUILD/fixture.aiff"
else
  "$TRANSCRIPTION_TEST_BUILD/transcription-tests"
fi
