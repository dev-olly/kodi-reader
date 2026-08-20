import Foundation

/// On-disk app data always lives in the sandboxed container for `com.olly.Folio`.
///
/// `FileManager.applicationSupportDirectory` follows the process: a signed,
/// sandboxed launch writes inside the container, but an unsigned Debug build
/// writes to `~/Library/Application Support/EpubReader` and looks like a
/// blank library. Recents, AI configs, and Kokoro models all use this root
/// so they cannot split across those two folders.
enum AppDataDirectory {
    static let folderName = "EpubReader"

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.olly.Folio"
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
                "Library/Containers/\(bundleID)/Data/Library/Application Support/\(folderName)",
                isDirectory: true
            )
    }

    /// Creates the directory if needed and returns it.
    @discardableResult
    static func prepare() -> URL {
        let url = root
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
