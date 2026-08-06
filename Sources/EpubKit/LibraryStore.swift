import Foundation

/// Reading positions, annotations, and the recents list, persisted as JSON.
///
/// A database would be overkill: the whole store is a few hundred kilobytes
/// even after years of reading, and a plain file keeps the app dependency-free
/// and the data trivially inspectable and backup-friendly.
public final class LibraryStore: @unchecked Sendable {
    /// Current on-disk schema. v1 notes decode as-is; missing `anchorStatus`
    /// defaults to `.unknown` on the Annotation type.
    public static let currentVersion = 2

    private struct Payload: Codable {
        var version: Int = LibraryStore.currentVersion
        var books: [String: BookRecord] = [:]
        var settingsJSON: Data?
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "library-store", qos: .utility)
    private var payload: Payload
    private let lock = NSLock()
    /// Coalesces the frequent position updates that arrive while reading.
    private var pendingSave: DispatchWorkItem?

    /// Schema version of the loaded (or empty) store.
    public var schemaVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return payload.version
    }

    public convenience init(applicationName: String = "EpubReader") throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent(applicationName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.init(fileURL: directory.appendingPathComponent("library.json"))
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        payload = LibraryStore.load(from: fileURL) ?? Payload()
    }

    private static func load(from url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard var payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        // v1 → v2 is a no-op body migration: Annotation.anchorStatus is optional
        // on decode. Bumping the version ensures the next write stamps v2.
        if payload.version < currentVersion {
            payload.version = currentVersion
        }
        return payload
    }

    // MARK: - Books

    public func record(for bookID: String) -> BookRecord? {
        lock.lock()
        defer { lock.unlock() }
        return payload.books[bookID]
    }

    public func upsert(_ record: BookRecord) {
        lock.lock()
        payload.books[record.id] = record
        lock.unlock()
        scheduleSave()
    }

    /// Applies a change to a stored book, creating nothing if it is unknown.
    public func update(_ bookID: String, _ transform: (inout BookRecord) -> Void) {
        lock.lock()
        if var record = payload.books[bookID] {
            transform(&record)
            payload.books[bookID] = record
        }
        lock.unlock()
        scheduleSave()
    }

    public func remove(bookID: String) {
        lock.lock()
        payload.books.removeValue(forKey: bookID)
        lock.unlock()
        scheduleSave()
    }

    /// Most recently opened books first.
    public func recentBooks(limit: Int = 12) -> [BookRecord] {
        lock.lock()
        defer { lock.unlock() }
        return payload.books.values
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Settings

    public func loadSettings<T: Decodable>(_ type: T.Type) -> T? {
        lock.lock()
        let data = payload.settingsJSON
        lock.unlock()
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func saveSettings<T: Encodable>(_ settings: T) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        lock.lock()
        payload.settingsJSON = data
        lock.unlock()
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeToDisk() }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Forces an immediate write, for app termination.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        writeToDisk()
    }

    private func writeToDisk() {
        lock.lock()
        let snapshot = payload
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        // Atomic so a crash mid-write cannot truncate the library.
        try? data.write(to: fileURL, options: .atomic)
    }
}
