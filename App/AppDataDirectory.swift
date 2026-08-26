import Foundation

/// On-disk app data always lives in the sandboxed container for `com.olly.KodiReader`.
///
/// `FileManager.applicationSupportDirectory` follows the process: a signed,
/// sandboxed launch writes inside the container, but an unsigned Debug build
/// writes to `~/Library/Application Support/KodiReader` and looks like a
/// blank library. Recents, AI configs, and Kokoro models all use this root
/// so they cannot split across those two folders.
enum AppDataDirectory {
    static let folderName = "KodiReader"
    static let bundleID = "com.olly.KodiReader"

    static var resolvedBundleID: String {
        Bundle.main.bundleIdentifier ?? bundleID
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static var root: URL {
        if isSandboxed {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folderName, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(resolvedBundleID)/Data/Library/Application Support/\(folderName)",
                isDirectory: true
            )
    }

    /// Creates the directory if needed, copies Folio-era data once, and returns it.
    @discardableResult
    static func prepare() -> URL {
        let url = root
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        LegacyFolioMigration.run(into: url)
        return url
    }
}
