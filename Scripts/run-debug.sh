#!/usr/bin/env bash
# Reuse one clearly named development app instead of making preview copies.
set -euo pipefail
cd "$(dirname "$0")/.."

DEBUG_DERIVED_DATA="${PWD}/.xcode-derived-data"
DEBUG_APP="${DEBUG_DERIVED_DATA}/Build/Products/Debug/Kodi Reader Debug.app"

xcodegen generate
xcodebuild \
  -project KodiReader.xcodeproj \
  -scheme KodiReader \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DEBUG_DERIVED_DATA" \
  KODI_PRODUCT_NAME='Kodi Reader Debug' \
  CODE_SIGNING_ALLOWED=NO \
  build

# The release and debug builds share a library. Let the running app flush its
# notes and drawings through the normal Quit handler before opening this build.
xcrun swift -module-cache-path "${DEBUG_DERIVED_DATA}/ModuleCache.noindex" -e '
import AppKit
import Foundation
func readers() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        let id = $0.bundleIdentifier ?? ""
        return (id == "com.olly.KodiReader" || id.hasPrefix("com.olly.KodiReader."))
            && $0.bundleURL?.pathExtension == "app"
    }
}
for app in readers() {
    guard app.terminate() else {
        fputs("Kodi Reader could not close normally. Finish saving and try again.\n", stderr)
        exit(1)
    }
}
let deadline = Date().addingTimeInterval(30)
while !readers().isEmpty && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard readers().isEmpty else {
    fputs("Kodi Reader is still saving or waiting for input. No second instance was opened.\n", stderr)
    exit(1)
}
'
open -n "$DEBUG_APP"
