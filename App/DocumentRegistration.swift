import AppKit
import CoreServices

/// Sparkle replaces the installed bundle. Remove leftover Launch Services
/// claims from older copies after relaunch, without touching books or app data.
enum DocumentRegistration {
    static func shouldUnregister(candidate: URL, current: URL,
                                 candidateVersion: String?, currentVersion: String) -> Bool {
        guard candidate.resolvingSymlinksInPath() != current.resolvingSymlinksInPath(),
              let candidateVersion, !candidateVersion.isEmpty else { return false }
        return candidateVersion.compare(currentVersion, options: .numeric) != .orderedDescending
    }

    static func refreshInstalledRelease() {
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let installations = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                             FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        guard installations.contains(current.deletingLastPathComponent()),
              Bundle.main.bundleIdentifier == "com.olly.KodiReader",
              Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") != nil,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }

        DispatchQueue.global(qos: .utility).async {
            let identifiers = ["com.olly.KodiReader", "com.olly.KodiReader.preview", "com.olly.KodiReader.sandbox"]
            var obsolete = Set<URL>()
            for identifier in identifiers {
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
                run(tool, arguments: ["-u"] + obsolete.map(\.path))
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
        } catch {
            NSLog("Kodi Reader: could not refresh document registration: %@", error.localizedDescription)
        }
    }
}
