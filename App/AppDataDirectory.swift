import Foundation

/// On-disk app data always lives in the sandboxed container for `com.olly.Folio`.
enum AppDataDirectory {
    static let folderName = "EpubReader"

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.olly.Folio"
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}
