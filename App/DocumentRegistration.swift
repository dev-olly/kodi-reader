import AppKit
import CoreServices

/// Keep the installed release's document claims separate from development
/// builds and legacy Folio registrations, without touching books or app data.
enum DocumentRegistration {
    static let bundleIdentifiers = ["com.olly.KodiReader", "com.olly.KodiReader.preview",
                                    "com.olly.KodiReader.sandbox", "com.olly.Folio",
                                    "com.olly.EpubReader"]

    static func isInstalled(_ url: URL) -> Bool {
        let installations = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                             FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return installations.contains {
            $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath().deletingLastPathComponent()
        }
    }

    static func shouldUnregister(candidate: URL, current: URL,
                                 candidateVersion: String?, currentVersion: String) -> Bool {
        guard candidate.resolvingSymlinksInPath() != current.resolvingSymlinksInPath() else { return false }
        // A newer local build must not advertise itself alongside the installed
        // release. Missing bundles can still have cached Launch Services claims.
        guard isInstalled(candidate), let candidateVersion, !candidateVersion.isEmpty else { return true }
        return candidateVersion.compare(currentVersion, options: .numeric) != .orderedDescending
    }

    static func refreshInstalledRelease() {
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard isInstalled(current),
              Bundle.main.bundleIdentifier == "com.olly.KodiReader",
              Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") != nil,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }

        DispatchQueue.global(qos: .utility).async {
            var obsolete = Set<URL>()
            for identifier in bundleIdentifiers {
                let urls = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
                for url in urls {
                    let candidateVersion = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    if shouldUnregister(candidate: url, current: current,
                                        candidateVersion: candidateVersion, currentVersion: version) {
                        obsolete.insert(url)
                    }
                }
            }
            let tool = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
            if !obsolete.isEmpty {
                // Separate calls let one invalid path fail without skipping
                // cleanup of the remaining registrations.
                for url in obsolete.sorted(by: { $0.path < $1.path }) {
                    run(tool, arguments: ["-u", url.path])
                }
            }
            run(tool, arguments: ["-f", current.path])
        }
    }

    private static func run(_ tool: URL, arguments: [String]) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                NSLog("Kodi Reader: document registration failed (%d): %@", process.terminationStatus,
                      arguments.joined(separator: " "))
            }
        } catch {
            NSLog("Kodi Reader: could not refresh document registration: %@", error.localizedDescription)
        }
    }
}
