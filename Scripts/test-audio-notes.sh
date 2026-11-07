#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
AUDIO_TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/kodi-audio-tests.XXXXXX")
trap 'rm -rf "$AUDIO_TEST_BUILD"' EXIT
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/kodi-note-module-cache" \
  -target "$(uname -m)-apple-macosx14.0" \
  App/Analytics/AnalyticsEvent.swift App/Audio/AudioNoteController.swift Tests/AppTests/AudioNoteControllerTests.swift \
  -o "$AUDIO_TEST_BUILD/audio-note-tests"
"$AUDIO_TEST_BUILD/audio-note-tests"

# Only the external model boundary is stubbed. The actual controller and its
# async state transitions run unchanged, with injected synthesis/output devices.
cat > "$AUDIO_TEST_BUILD/FluidAudio.swift" <<'SWIFT'
import Foundation
public enum ParadeeVoice { case afHeart }
public struct ParadeeManager {
    public enum Version { case v12 }
    public enum Variant { case int8 }
    public init(version: Version, variant: Variant, directory: URL) {}
    public var sampleRate: Int { 24_000 }
    public func initialize() async throws { fatalError("Test must inject model preparation") }
    public func synthesize(text: String, voice: ParadeeVoice) async throws -> [Float] { fatalError("Test must inject synthesis") }
}
SWIFT
xcrun swiftc -emit-module -emit-library -module-name FluidAudio \
  -module-cache-path "${TMPDIR:-/tmp}/kodi-note-module-cache" \
  -target "$(uname -m)-apple-macosx14.0" \
  "$AUDIO_TEST_BUILD/FluidAudio.swift" -emit-module-path "$AUDIO_TEST_BUILD/FluidAudio.swiftmodule" \
  -o "$AUDIO_TEST_BUILD/libFluidAudio.dylib"
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/kodi-note-module-cache" \
  -target "$(uname -m)-apple-macosx14.0" \
  -I "$AUDIO_TEST_BUILD" -L "$AUDIO_TEST_BUILD" -lFluidAudio \
  -Xlinker -rpath -Xlinker "$AUDIO_TEST_BUILD" \
  App/Analytics/AnalyticsEvent.swift App/Audio/AudioNoteController.swift \
  App/Audio/ReadAloudController.swift Tests/AppTests/ReadAloudAnalyticsTests.swift \
  -o "$AUDIO_TEST_BUILD/read-aloud-tests"
"$AUDIO_TEST_BUILD/read-aloud-tests"
