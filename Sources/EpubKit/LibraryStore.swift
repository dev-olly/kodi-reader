import Foundation

/// Reading positions, annotations, and the recents list, persisted as JSON.
///
/// A database would be overkill: the whole store is a few hundred kilobytes
/// even after years of reading, and a plain file keeps the app dependency-free
/// and the data trivially inspectable and backup-friendly.
public final class LibraryStore: @unchecked Sendable {
    /// Current on-disk schema. v1 notes decode as-is; missing `anchorStatus`
    /// defaults to `.unknown` on the Annotation type. v3 adds optional
    /// `sourceURL` on BookRecord for frozen webpages; v4 adds PDF documents.
    public static let currentVersion = 5

    private struct Payload: Codable {
        var version: Int = LibraryStore.currentVersion
        var books: [String: BookRecord] = [:]
        var settingsJSON: Data?
        var appearanceMigrationVersion: Int?
        var settingsBeforeAppearanceMigration: Data?
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "library-store", qos: .utility)
    private var payload: Payload
    private var durableRecords: [String: BookRecord] = [:]
    private let lock = NSLock()
    private let ioLock = NSRecursiveLock()
    public var onDurableChange: (@Sendable () -> Void)?
    public private(set) var migrationError: String?
    /// Coalesces the frequent position updates that arrive while reading.
    private var pendingSave: DispatchWorkItem?
    /// Excalidraw scenes live next to `library.json`, keyed by book.
    public let drawingStore: DrawingStore

    /// Directory containing `library.json` and the `Books/` import folder.
    public var rootDirectory: URL {
        fileURL.deletingLastPathComponent()
    }

    /// Durable copies of opened documents live here so Recents never needs sandbox re-grants.
    public var booksDirectory: URL {
        rootDirectory.appendingPathComponent("Books", isDirectory: true)
    }

    /// Schema version of the loaded (or empty) store.
    public var schemaVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return payload.version
    }

    public convenience init(applicationName: String = "KodiReader") throws {
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
        let loaded = LibraryStore.load(from: fileURL)
        payload = loaded ?? Payload()
        if FileManager.default.fileExists(atPath: fileURL.path), loaded == nil {
            migrationError = "The local library could not be read. Restore library.before-icloud.json before enabling sync."
        }
        durableRecords = payload.books
        drawingStore = DrawingStore(rootDirectory: fileURL.deletingLastPathComponent())
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent("library.before-icloud.json")
        if FileManager.default.fileExists(atPath: fileURL.path), !FileManager.default.fileExists(atPath: backup.path) {
            do { try FileManager.default.copyItem(at: fileURL, to: backup) }
            catch { migrationError = error.localizedDescription }
        }
        for id in payload.books.keys {
            if payload.books[id]?.chats == nil, let messages = payload.books[id]?.chatMessages, !messages.isEmpty {
                let thread = ChatThread.wrappingLegacyMessages(messages)
                payload.books[id]?.chats = [thread]
                payload.books[id]?.activeChatID = thread.id
            }
        }
    }

    // MARK: - Imported book files

    /// Relative path stored on `BookRecord.importedRelativePath`.
    public static func relativeImportedPath(
        for bookID: String,
        kind: DocumentKind = .epub
    ) -> String {
        "Books/\(sanitizedFileName(for: bookID)).\(kind.rawValue)"
    }

    public static func sanitizedFileName(for bookID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = bookID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let name = String(scalars)
        return name.isEmpty ? "book" : String(name.prefix(120))
    }

    public func importedURL(for bookID: String, kind: DocumentKind = .epub) -> URL {
        booksDirectory.appendingPathComponent(
            Self.sanitizedFileName(for: bookID) + ".\(kind.rawValue)",
            isDirectory: false
        )
    }

    /// Resolved imported file URL when the copy exists on disk.
    public func existingImportedURL(for record: BookRecord) -> URL? {
        if let relative = record.importedRelativePath {
            let url = rootDirectory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let fallback = importedURL(for: record.id, kind: record.documentKind)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    public func isImportedURL(_ url: URL) -> Bool {
        let books = booksDirectory.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        return path == books || path.hasPrefix(books + "/")
    }

    /// Copies `source` into `Books/` unless it is already the imported file.
    @discardableResult
    public func importBook(
        from source: URL,
        bookID: String,
        kind: DocumentKind = .epub
    ) throws -> URL {
        try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        let destination = importedURL(for: bookID, kind: kind)
        let sourcePath = source.resolvingSymlinksInPath().path
        let destPath = destination.resolvingSymlinksInPath().path
        if sourcePath == destPath {
            return destination
        }
        if FileManager.default.fileExists(atPath: destPath) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    public func removeImportedBook(bookID: String, kind: DocumentKind = .epub) {
        let url = importedURL(for: bookID, kind: kind)
        try? FileManager.default.removeItem(at: url)
    }

    private static func load(from url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard var payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        // v1 → current is a no-op body migration: new Annotation/BookRecord fields
        // are optional on decode. Bumping the version stamps the current schema.
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

    /// Rename the library entry without changing its identity or source file.
    public func renameBook(_ bookID: String, to title: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryStoreError.emptyTitle }
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock()
        guard var record = payload.books[bookID] else {
            lock.unlock()
            throw LibraryStoreError.missingBook
        }
        let previous = record
        record.title = name
        payload.books[bookID] = record
        lock.unlock()
        do { try writeToDisk() }
        catch {
            lock.lock(); payload.books[bookID] = previous; lock.unlock()
            throw error
        }
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

    /// Applies a change and writes the library immediately, surfacing disk
    /// errors to UI flows that need an accurate saved/failed state.
    public func updateAndFlush(_ bookID: String, _ transform: (inout BookRecord) -> Void) throws {
        lock.lock()
        guard var record = payload.books[bookID] else {
            lock.unlock()
            throw LibraryStoreError.missingBook
        }
        transform(&record)
        payload.books[bookID] = record
        lock.unlock()
        pendingSave?.cancel()
        pendingSave = nil
        try writeToDisk()
    }

    public func remove(bookID: String) {
        lock.lock()
        let removed = payload.books.removeValue(forKey: bookID)
        lock.unlock()
        if let relative = removed?.importedRelativePath {
            try? FileManager.default.removeItem(at: rootDirectory.appendingPathComponent(relative))
        } else {
            removeImportedBook(bookID: bookID, kind: removed?.documentKind ?? .epub)
        }
        drawingStore.deleteAllScenes(bookID: bookID)
        scheduleSave()
    }

    /// Most recently opened books first.
    public func recentBooks(limit: Int = 12) -> [BookRecord] {
        lock.lock()
        defer { lock.unlock() }
        return payload.books.values
            .filter { !$0.isHiddenFromRecents }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// All records, including books hidden from Recents and cloud-only books.
    public func allBooks() -> [BookRecord] {
        lock.lock(); defer { lock.unlock() }
        return payload.books.values.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    public func durableBooks() -> [BookRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(durableRecords.values)
    }

    public func record(cloudIdentity: String) -> BookRecord? {
        allBooks().first { $0.cloudIdentity == cloudIdentity }
    }

    public func hideFromRecents(_ id: String) {
        update(id) { $0.isHiddenFromRecents = true }
    }

    public func removeLocalDownload(_ id: String) throws {
        guard let record = record(for: id), record.cloudFile != nil else { throw SyncFailure.missingFile }
        if let url = existingImportedURL(for: record) { try FileManager.default.removeItem(at: url) }
        try updateAndFlush(id) {
            $0.importedRelativePath = nil; $0.fileBookmark = nil; $0.lastKnownPath = nil
        }
    }

    /// Persist received changes without turning them into new outgoing edits.
    public func applyRemoteChanges(_ records: [BookRecord]) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock()
        let previous = payload
        for record in records { payload.books[record.id] = record }
        lock.unlock()
        do { try writeToDisk(notify: false) }
        catch { lock.lock(); payload = previous; lock.unlock(); throw error }
    }

    public func deleteForSync(_ id: String) throws {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock(); let previous = payload; payload.books[id] = nil; lock.unlock()
        do { try writeToDisk(notify: false) }
        catch { lock.lock(); payload = previous; lock.unlock(); throw error }
        if let record = previous.books[id], let file = existingImportedURL(for: record) {
            try? FileManager.default.removeItem(at: file)
        }
        drawingStore.deleteAllScenes(bookID: id)
    }

    public func checkpoint() throws {
        pendingSave?.cancel(); pendingSave = nil
        drawingStore.flush()
        try writeToDisk()
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

    /// Back up and replace settings in one payload, so interruption cannot
    /// persist the new values without also persisting the migration marker.
    public func migrateAppearanceSettings<T: Codable>(
        defaultSettings: T, transform: (inout T) -> Void
    ) throws -> T {
        lock.lock()
        do {
            var settings = try payload.settingsJSON.map {
                try JSONDecoder().decode(T.self, from: $0)
            } ?? defaultSettings
            guard (payload.appearanceMigrationVersion ?? 0) < 1 else {
                lock.unlock()
                return settings
            }
            transform(&settings)
            let encoded = try JSONEncoder().encode(settings)
            payload.settingsBeforeAppearanceMigration = payload.settingsJSON
            payload.settingsJSON = encoded
            payload.appearanceMigrationVersion = 1
            lock.unlock()
            flush()
            return settings
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func settingsBeforeAppearanceMigration<T: Decodable>(_ type: T.Type) -> T? {
        lock.lock()
        let data = payload.settingsBeforeAppearanceMigration
        lock.unlock()
        return data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in try? self?.writeToDisk() }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Forces an immediate write, for app termination.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        drawingStore.flush()
        try? writeToDisk()
    }

    private func writeToDisk(notify: Bool = true) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        lock.lock()
        let snapshot = payload
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        // Atomic so a crash mid-write cannot truncate the library.
        try data.write(to: fileURL, options: .atomic)
        lock.lock(); durableRecords = snapshot.books; lock.unlock()
        if notify { onDurableChange?() }
    }
}

public enum LibraryStoreError: LocalizedError {
    case missingBook
    case emptyTitle

    public var errorDescription: String? {
        switch self {
        case .missingBook:
            return "Could not save because the book is no longer open."
        case .emptyTitle:
            return "Enter a name for this document."
        }
    }
}
