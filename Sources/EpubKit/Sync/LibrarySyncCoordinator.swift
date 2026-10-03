import CloudKit
import Foundation
import Observation
import OSLog

@MainActor @Observable
public final class LibrarySyncCoordinator {
    public private(set) var preferences: SyncPreferences
    public let status = SyncStatus()
    public var onLibraryChanged: (() -> Void)?
    /// App UI owns edit lifetimes. Received changes are journaled until editors are safe.
    public var isEditing: () -> Bool = { false }
    public var isEntityEditing: (SyncEntity) -> Bool = { _ in false }
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let logger = Logger(subsystem: "com.olly.KodiReader", category: "Sync")
    @ObservationIgnored private let transport: any SyncTransport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var journal: SyncJournal
    @ObservationIgnored private let journalURL: URL
    @ObservationIgnored private let chunkDirectory: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastPositionSend = Date.distantPast
    @ObservationIgnored private var manifests: [String: (Date, Int64, BlobManifest)] = [:]
    @ObservationIgnored private var sourceFiles: [String: URL] = [:]
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var retryFailures = 0
    @ObservationIgnored private var activeMaterializations = 0
    @ObservationIgnored private var cacheCleanup = Set<String>()
    @ObservationIgnored private var stopped: Bool

    public init(store: LibraryStore, transport: any SyncTransport, now: @escaping () -> Date = Date.init,
                journalURL overrideJournalURL: URL? = nil, active: Bool = true) {
        self.store = store; self.transport = transport; self.now = now
        stopped = !active
        let root = store.rootDirectory.appendingPathComponent("Sync", isDirectory: true)
        journalURL = overrideJournalURL ?? root.appendingPathComponent("journal.json")
        chunkDirectory = root.appendingPathComponent("Chunks", isDirectory: true)
        if let data = try? Data(contentsOf: journalURL), let saved = try? JSONDecoder().decode(SyncJournal.self, from: data) {
            journal = saved
        } else {
            journal = SyncJournal()
            // Never silently overwrite a damaged journal and then republish deleted data.
            if FileManager.default.fileExists(atPath: journalURL.path) { journal.requiresAcknowledgement = true }
        }
        preferences = journal.preferences
        lastPositionSend = journal.lastPositionSend ?? .distantPast
        status.lastSuccessfulSync = journal.lastSuccessfulSync
        status.requiresAcknowledgement = journal.requiresAcknowledgement
        transport.onEvent = { [weak self] event in try await self?.handle(event) }
        store.onDurableChange = { [weak self] in Task.detached { @MainActor in self?.localChanged() } }
        if journal.requiresAcknowledgement {
            preferences.mode = .off; status.phase = .unavailable; status.message = SyncFailure.accountChanged.localizedDescription
        }
    }

    public func setPreferences(_ value: SyncPreferences, acknowledge: Bool = false) async {
        if journal.requiresAcknowledgement, !acknowledge { return }
        generation += 1; task?.cancel(); debounce?.cancel()
        await transport.stop()
        await task?.value
        task = nil
        if acknowledge && journal.requiresAcknowledgement {
            if let previous = journal.accountID {
                let archive = journalURL.deletingLastPathComponent().appendingPathComponent("Accounts", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
                    try SyncCoding.encode(journal).write(to: archive.appendingPathComponent(SyncCoding.hash(Data(previous.utf8)) + ".json"), options: .atomic)
                } catch { fail(error); return }
            }
            // A manifest from a previous account is not a local book file and cannot
            // be published into the new account without its binary contents.
            do {
                let localBooks = store.allBooks().map { record in
                    var copy = record; copy.cloudFile = nil; return copy
                }
                try store.applyRemoteChanges(localBooks)
            } catch { fail(error); return }
            journal.requiresAcknowledgement = false; status.requiresAcknowledgement = false
            journal.accountID = nil
            journal.base = [:]; journal.local = [:]; journal.pending = [:]
            journal.serverFields = [:]; journal.engineStates = [:]; journal.deferred = []
            journal.collectedTombstones = nil
            journal.assetGenerations = nil
            journal.pendingRestorations = nil
        }
        preferences = value; journal.preferences = value
        do { try persist() } catch { fail(error); return }
        if value.mode == .off { status.phase = .off; status.message = nil }
        else { syncNow() }
    }

    /// Stops a provider without modifying its saved preferences or pending journal.
    public func stop() async {
        stopped = true
        generation += 1; task?.cancel(); debounce?.cancel()
        await transport.stop()
        await task?.value
        task = nil
        transport.onEvent = nil
    }

    public func syncNow() {
        guard !stopped, preferences.mode != .off, !journal.requiresAcknowledgement, task == nil else { return }
        let token = generation
        // CloudKit invokes the delegate inside a task-local callback context.
        // New sync work must not inherit it, even when it runs after a debounce.
        task = Task.detached { @MainActor [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.purgeRemovedDownloads() }
            do { try await self.synchronize(token: token) }
            catch is CancellationError {}
            catch { self.fail(error) }
        }
    }

    public func checkpoint() {
        do { try store.checkpoint(); try capture(); try persist() }
        catch { fail(error) }
    }

    /// Bring the current provider's remote metadata into the local library
    /// before the app starts copying that library to another provider.
    public func prepareProviderSwitch() async throws {
        try store.checkpoint(); try capture(); try persist()
        guard !stopped, preferences.mode != .off else { return }
        await task?.value
        syncNow()
        await task?.value
        if !journal.deferred.isEmpty {
            throw NSError(domain: "KodiSync", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "Finish editing the open note or Ask AI reply before switching cloud providers."])
        }
        if [.error, .offline, .unavailable, .storageFull].contains(status.phase) {
            throw NSError(domain: "KodiSync", code: 5, userInfo: [NSLocalizedDescriptionKey:
                status.message ?? "Sync the current cloud before copying its library to another provider."])
        }
        try store.checkpoint(); try capture(); try persist()
    }

    public func resumeDeferredChanges() {
        guard !isEditing(), !journal.deferred.isEmpty, preferences.mode != .off else { return }
        syncNow()
    }

    public func cloudFile(for record: BookRecord) -> BlobManifest? { record.cloudFile }
    public func isLocalRecovery(_ recordID: String) -> Bool { journal.detachedBooks?.contains(recordID) == true }

    public func download(_ record: BookRecord) async throws -> URL {
        do { return try await performDownload(record) }
        catch { fail(error); throw error }
    }

    public func removeDownload(_ record: BookRecord) throws {
        try store.removeLocalDownload(record.id)
        cacheCleanup.formUnion(record.cloudFile?.chunks ?? [])
        purgeRemovedDownloads(); onLibraryChanged?()
    }

    private func purgeRemovedDownloads() {
        guard task == nil, activeMaterializations == 0 else { return }
        for hash in cacheCleanup where hash.count == 64 && hash.allSatisfy({ $0.isHexDigit }) {
            try? FileManager.default.removeItem(at: chunkDirectory.appendingPathComponent(hash))
        }
        cacheCleanup.removeAll()
    }

    private func performDownload(_ record: BookRecord) async throws -> URL {
        guard preferences.mode == .booksAndNotes else { throw SyncFailure.categoryDisabled }
        guard let manifest = record.cloudFile, let identity = record.cloudIdentity else { throw SyncFailure.missingFile }
        let token = generation
        _ = try await checkedAccount()
        let destination = store.importedURL(for: record.id, kind: record.documentKind)
        status.downloads[record.id] = 0
        defer { status.downloads[record.id] = nil }
        try await materialize(manifest, to: destination, token: token, scope: "book:\(identity):metadata") { self.status.downloads[record.id] = $0 }
        try check(token)
        guard var latest = store.record(for: record.id) else { throw SyncFailure.missingFile }
        latest.importedRelativePath = LibraryStore.relativeImportedPath(for: record.id, kind: record.documentKind)
        try store.applyRemoteChanges([latest])
        onLibraryChanged?()
        return destination
    }

    public func deleteEverywhere(_ record: BookRecord) throws {
        try store.checkpoint(); try capture()
        guard let identity = record.cloudIdentity else { try store.deleteForSync(record.id); onLibraryChanged?(); return }
        for (id, var entity) in journal.local where entity.bookID == identity && !entity.deleted {
            cacheCleanup.formUnion(try blobs(in: entity).flatMap(\.chunks))
            entity.deleted = true; entity.body = Data(); entity.modifiedAt = Date(); entity.deviceID = journal.deviceID
            journal.local[id] = entity; journal.pending[id] = entity
        }
        // Commit deletion intent before removing the local copy.
        try persist(); try store.deleteForSync(record.id)
        purgeRemovedDownloads()
        onLibraryChanged?(); schedule()
    }

    private func localChanged() {
        guard !stopped else { return }
        do { try capture(); try persist(); schedule() }
        catch { fail(error) }
    }

    private func schedule() {
        guard !stopped, preferences.mode != .off, !journal.requiresAcknowledgement else { return }
        debounce?.cancel()
        let onlyPositions = journal.pending.values.filter { allowed($0) }.allSatisfy { $0.kind == .position }
        let seconds = onlyPositions ? max(2, 30 - now().timeIntervalSince(lastPositionSend)) : 2
        debounce = Task.detached { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)); self?.syncNow() } catch {}
        }
    }

    private func checkedAccount() async throws -> String {
        let account = try await transport.accountID()
        if let previous = journal.accountID, previous != account {
            try suspend(SyncFailure.accountChanged); throw SyncFailure.accountChanged
        }
        journal.accountID = account; try persist()
        return account
    }

    private func synchronize(token: Int) async throws {
        guard Date() >= retryAfter else { return }
        if let error = store.migrationError { throw NSError(domain: "KodiSync", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        status.phase = .syncing; status.message = nil
        try store.checkpoint()
        try await prepareIdentities()
        try await prepareBookManifests(token: token)
        try capture(); try persist()
        _ = try await checkedAccount(); try check(token)
        try await transport.configure(aiEnabled: preferences.syncAIHistory, states: journal.engineStates)
        // Fetch and merge before adding any local outgoing records to the engine.
        try await transport.fetch(); try check(token)
        if !isEditing() {
            let deferred = journal.deferred
            for entity in deferred where allowed(entity) && !isEntityEditing(entity) {
                try await receive(entity, token: token)
                journal.deferred.removeAll { $0.id == entity.id && $0 == entity }
                try persist()
            }
        }
        // Persist locally captured edits before committing received engine checkpoints.
        try capture(); try persist()
        try await prepareRestorations(token: token)
        try capture(); try persist()
        let restoringBooks = Set(journal.pending.values.filter {
            $0.kind == .book && !$0.deleted && journal.base[$0.id]?.deleted == true
        }.map(\.bookID))
        let deferredIDs = Set(journal.deferred.map(\.id)).union(journal.pending.values.filter {
            restoringBooks.contains($0.bookID)
        }.map(\.id))
        let positionDue = now().timeIntervalSince(lastPositionSend) >= 30
        let outgoing = journal.pending.values.filter {
            allowed($0) && !deferredIDs.contains($0.id) && ($0.kind != .position || positionDue || $0.deleted)
        }.sorted { $0.id < $1.id }
        for entity in outgoing where !entity.deleted {
            for blob in try blobs(in: entity) {
                if entity.kind == .book, preferences.mode != .booksAndNotes { continue }
                if let source = sourceFiles[blob.hash] {
                    let directory = chunkDirectory
                    try await Task.detached { try blob.stage(source, directory: directory) }.value
                }
                for (index, hash) in blob.chunks.enumerated() {
                    try check(token)
                    let chunk = chunkDirectory.appendingPathComponent(hash)
                    // A remote recovery copy's blob is already published, or hydrated locally.
                    if FileManager.default.fileExists(atPath: chunk.path) {
                        try await transport.uploadChunk(hash: hash, file: chunk, scope: entity.id, bookID: entity.bookID, blobHash: blob.assetKey, index: index)
                    }
                }
            }
        }
        try check(token)
        try await transport.send(outgoing, serverFields: journal.serverFields)
        try check(token)
        let tombstones = try journal.base.values.filter {
            guard $0.deleted else { return false }
            return journal.collectedTombstones?.contains(SyncCoding.hash(try SyncCoding.encode($0))) != true
        }
        if !tombstones.isEmpty {
            try await transport.collectDeletedAssets(tombstones)
            for entity in tombstones {
                journal.collectedTombstones = (journal.collectedTombstones ?? []).union([SyncCoding.hash(try SyncCoding.encode(entity))])
            }
            try persist()
        }
        try check(token)
        if outgoing.contains(where: { $0.kind == .position && !$0.deleted }) {
            lastPositionSend = now(); journal.lastPositionSend = lastPositionSend; try persist()
        }
        if journal.pending.values.contains(where: allowed) || journal.deferred.contains(where: allowed) {
            status.phase = .syncing
            if journal.pending.values.contains(where: { allowed($0) && !deferredIDs.contains($0.id) }) { schedule() }
            else { status.message = "Waiting for the open editor or AI response to finish." }
        } else {
            status.phase = .synced
            journal.lastSuccessfulSync = Date(); status.lastSuccessfulSync = journal.lastSuccessfulSync
            try persist()
        }
        logger.info("sync pass: sent \(outgoing.count, privacy: .public), pending \(self.journal.pending.count, privacy: .public)")
        retryFailures = 0
    }

    private func allowed(_ entity: SyncEntity) -> Bool {
        preferences.mode != .off && (entity.kind != .chat || preferences.syncAIHistory)
    }

    private func prepareRestorations(token: Int) async throws {
        let books = journal.pending.values.filter {
            $0.kind == .book && !$0.deleted && journal.base[$0.id]?.deleted == true
        }
        for entity in books {
            try check(token)
            guard !isEditing(), !isEntityEditing(entity) else { continue }
            let generation = journal.pendingRestorations?[entity.id] ?? UUID().uuidString
            journal.pendingRestorations = (journal.pendingRestorations ?? [:]).merging([entity.id: generation]) { _, new in new }
            for child in journal.local.values where child.bookID == entity.bookID && !child.deleted {
                journal.assetGenerations = (journal.assetGenerations ?? [:]).merging([child.id: generation]) { _, new in new }
            }
            try capture(); try persist()
            var revival = journal.pending[entity.id] ?? entity
            var metadata = try revival.value(SyncedBook.self)
            metadata.file = nil; revival.body = try SyncCoding.encode(metadata)
            // Clear the old deletion before starting replacement assets. The complete
            // manifest is still published only after all replacement chunks succeed.
            try await transport.send([revival], serverFields: journal.serverFields)
            try check(token)
            guard journal.base[entity.id]?.deleted == false else {
                throw NSError(domain: "KodiSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "The book is still deleted in iCloud. Try Sync Now to finish re-importing it."])
            }
        }
    }

    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation, preferences.mode != .off, !journal.requiresAcknowledgement else { throw CancellationError() }
    }

    private func prepareIdentities() async throws {
        var updated: [BookRecord] = []
        for book in store.allBooks() where book.cloudIdentity == nil && journal.detachedBooks?.contains(book.id) != true {
            guard let file = store.existingImportedURL(for: book) else { continue }
            let kind = book.documentKind
            let identity = try await Task.detached { try BlobManifest.bookIdentity(file: file, kind: kind) }.value
            if var latest = store.record(for: book.id) { latest.cloudIdentity = identity; updated.append(latest) }
        }
        if !updated.isEmpty { try store.applyRemoteChanges(updated); onLibraryChanged?() }
    }

    private func prepareBookManifests(token: Int) async throws {
        guard preferences.mode == .booksAndNotes else { return }
        for book in store.durableBooks() where book.cloudIdentity != nil {
            guard let file = store.existingImportedURL(for: book) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let date = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if let cached = manifests[file.path], cached.0 == date, cached.1 == size { continue }
            let value = try await Task.detached { try BlobManifest.describe(file) }.value
            try check(token)
            manifests[file.path] = (date, size, value); sourceFiles[value.hash] = file
        }
    }

    private func manifest(for file: URL) throws -> BlobManifest {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let date = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if let cached = manifests[file.path], cached.0 == date, cached.1 == size {
            sourceFiles[cached.2.hash] = file; return cached.2
        }
        let value = try BlobManifest.describe(file)
        manifests[file.path] = (date, size, value); sourceFiles[value.hash] = file
        return value
    }

    /// Reconstruct pending work from durable local data, including deletions made while paused.
    private func capture() throws {
        if let error = store.migrationError { throw NSError(domain: "KodiSync", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        var current: [String: SyncEntity] = [:]
        func add<T: Encodable>(_ value: T, _ book: String, _ kind: SyncEntityKind, _ key: String) throws {
            var entity = SyncEntity(bookID: book, kind: kind, key: key, body: try SyncCoding.encode(value), deviceID: journal.deviceID)
            if let old = journal.local[entity.id], old.body == entity.body, !old.deleted { entity = old }
            current[entity.id] = entity
        }
        for book in store.durableBooks() {
            guard let identity = book.cloudIdentity else { continue }
            let metadataID = "book:\(identity):metadata"
            let rememberedFile = try journal.local[metadataID].flatMap { $0.deleted ? nil : try $0.value(SyncedBook.self).file }
            var file = book.cloudFile ?? rememberedFile
            if preferences.mode == .booksAndNotes, let source = store.existingImportedURL(for: book) {
                // Whole book hashes are prepared off the main actor before sending.
                if let cached = manifests[source.path] { file = cached.2; sourceFiles[cached.2.hash] = source }
            }
            if let generation = journal.assetGenerations?[metadataID] { file?.generation = generation }
            let hasLocalOrigin = book.id != identity || store.existingImportedURL(for: book) != nil
            if hasLocalOrigin || journal.local[metadataID] != nil {
                let publicSource = book.sourceURL.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
                try add(SyncedBook(title: book.title, author: book.author, kind: book.documentKind, sourceURL: publicSource, file: file), identity, .book, "metadata")
            }
            let positionID = "position:\(identity):position"
            if (hasLocalOrigin || journal.local[positionID] != nil) && !(journal.local[positionID]?.deleted == true && book.position == nil) {
                try add(SyncedPosition(locator: book.position, progress: book.progress, lastOpenedAt: book.lastOpenedAt), identity, .position, "position")
            }
            for var note in book.annotations {
                note.anchorStatus = .unknown
                let drawingFile = store.drawingStore.sceneURL(bookID: book.id, annotationID: note.id)
                var drawing = note.hasDrawing && FileManager.default.fileExists(atPath: drawingFile.path) ? try manifest(for: drawingFile) : nil
                drawing?.generation = journal.assetGenerations?["annotation:\(identity):\(note.id.uuidString)"]
                // Keep remote drawing references while an asset hydration is deferred.
                try add(SyncedAnnotation(annotation: note, drawing: drawing), identity, .annotation, note.id.uuidString)
            }
            for bookmark in book.bookmarks { try add(bookmark, identity, .bookmark, bookmark.id.uuidString) }
            if preferences.syncAIHistory || journal.local.values.contains(where: { $0.bookID == identity && $0.kind == .chat }) {
                for chat in book.conversationThreads { try add(chat, identity, .chat, chat.id.uuidString) }
            }
        }
        for (id, value) in current {
            if journal.local[id] != value {
                journal.local[id] = value
                journal.pending[id] = value
            }
        }
        for (id, var old) in journal.local where current[id] == nil && !old.deleted {
            old.deleted = true; old.body = Data(); old.modifiedAt = Date(); old.deviceID = journal.deviceID
            journal.local[id] = old; journal.pending[id] = old
        }
    }

    private func handle(_ event: SyncTransportEvent) async throws {
        switch event {
        case .received(let entity, let fields):
            guard allowed(entity) else { return }
            try capture()
            journal.serverFields[entity.id] = fields
            if isEditing() || isEntityEditing(entity) {
                journal.deferred.removeAll { $0.id == entity.id }
                journal.deferred.append(entity); try persist()
                status.phase = .syncing; status.message = "Waiting for the open editor or AI response to finish."
            } else {
                try await receive(entity, token: generation)
                if journal.pending.values.contains(where: allowed) { schedule() }
            }
        case .acknowledged(let entity, let fields):
            journal.base[entity.id] = entity; journal.serverFields[entity.id] = fields
            if entity.kind == .book { journal.pendingRestorations?[entity.id] = nil }
            if journal.pending[entity.id] == entity { journal.pending[entity.id] = nil }
            if entity.kind == .book, !entity.deleted, var book = store.record(cloudIdentity: entity.bookID) {
                book.cloudFile = try entity.value(SyncedBook.self).file
                try store.applyRemoteChanges([book])
            }
            try persist(); onLibraryChanged?()
        case .state(let zone, let data): journal.engineStates[zone] = data; try persist()
        case .accountChanged: try suspend(SyncFailure.accountChanged)
        case .cloudReset: try suspend(SyncFailure.cloudReset)
        case .failed(let error): fail(error)
        }
    }

    private func receive(_ remote: SyncEntity, token: Int) async throws {
        try check(token)
        // A book tombstone also suppresses late-arriving child records.
        let parentID = "book:\(remote.bookID):metadata"
        if remote.kind != .book, journal.local[parentID]?.deleted == true { return }
        let local = journal.pending[remote.id]
        let resolved = try local.map { try SyncMerge.resolve(local: $0, remote: remote, ancestor: journal.base[remote.id]) } ?? [remote]
        if remote.kind == .book, resolved.contains(where: { $0.id == remote.id && $0.deleted }) {
            try preserveEditsBeforeBookDeletion(remote.bookID)
        }
        // Materialize recovery copies before replacing or deleting their source drawing.
        for entity in resolved.sorted(by: { $0.id != remote.id && $1.id == remote.id }) {
            try await apply(entity, token: token)
            if let generation = try blobs(in: entity).first?.generation {
                journal.assetGenerations = (journal.assetGenerations ?? [:]).merging([entity.id: generation]) { _, new in new }
            }
            journal.local[entity.id] = entity
            if entity == remote { journal.pending[entity.id] = nil }
            else { journal.pending[entity.id] = entity }
        }
        journal.base[remote.id] = remote
        try persist(); onLibraryChanged?()
    }

    private func preserveEditsBeforeBookDeletion(_ identity: String) throws {
        let edits = journal.pending.values.filter {
            $0.bookID == identity && !$0.deleted && [.annotation, .bookmark, .chat].contains($0.kind)
        }.sorted { $0.id < $1.id }
        guard !edits.isEmpty, let sourceRecord = store.record(cloudIdentity: identity) else { return }
        var original = sourceRecord
        let seed = edits.map { $0.id + SyncCoding.hash($0.body) }.joined()
        let recoveredID = "recovered-" + SyncCoding.hash(Data((identity + seed).utf8))
        let oldID = original.id
        original.id = recoveredID; original.cloudIdentity = nil; original.cloudFile = nil
        original.title = "Recovered version: " + original.title; original.isHiddenFromRecents = false
        if let file = store.existingImportedURL(for: sourceRecord) {
            _ = try store.importBook(from: file, bookID: recoveredID, kind: original.documentKind)
            original.importedRelativePath = LibraryStore.relativeImportedPath(for: recoveredID, kind: original.documentKind)
        }
        for note in original.annotations where note.hasDrawing {
            if let scene = store.drawingStore.loadScene(bookID: oldID, annotationID: note.id) {
                let destination = store.drawingStore.sceneURL(bookID: recoveredID, annotationID: note.id)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try scene.write(to: destination, options: .atomic)
            }
        }
        journal.detachedBooks = (journal.detachedBooks ?? []).union([recoveredID]); try persist()
        try store.applyRemoteChanges([original])
    }

    private func apply(_ entity: SyncEntity, token: Int) async throws {
        var book = store.record(cloudIdentity: entity.bookID) ?? BookRecord(
            id: entity.bookID, title: "Synced book", author: "", documentKind: entity.bookID.hasPrefix("pdf-") ? .pdf : .epub)
        book.cloudIdentity = entity.bookID
        if entity.deleted, entity.kind != .book {
            if entity.kind == .position {
                book.position = nil; book.progress = 0; try store.applyRemoteChanges([book]); return
            }
            guard let key = entity.id.split(separator: ":").last, let id = UUID(uuidString: String(key)) else { throw SyncFailure.unsupportedSchema }
            switch entity.kind {
            case .annotation:
                book.annotations.removeAll { $0.id == id }
                store.drawingStore.deleteScene(bookID: book.id, annotationID: id)
            case .bookmark: book.bookmarks.removeAll { $0.id == id }
            case .chat:
                book.chats = book.conversationThreads.filter { $0.id != id }
                if book.activeChatID == id { book.activeChatID = nil; book.chatMessages = nil }
            default: break
            }
            try store.applyRemoteChanges([book]); return
        }
        if entity.kind == .book {
            if entity.deleted { try store.deleteForSync(book.id); return }
            let value = try entity.value(SyncedBook.self)
            book.title = value.title; book.author = value.author; book.documentKind = value.kind
            book.sourceURL = value.sourceURL.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            book.cloudFile = value.file
        } else if entity.kind == .annotation {
            let value = try entity.value(SyncedAnnotation.self)
            let id = value.annotation.id
            if !entity.deleted, let drawing = value.drawing {
                try await materialize(drawing, to: store.drawingStore.sceneURL(bookID: book.id, annotationID: id), token: token, scope: entity.id)
            }
            book.annotations.removeAll { $0.id == id }
            if !entity.deleted { book.annotations.append(value.annotation) }
            else { store.drawingStore.deleteScene(bookID: book.id, annotationID: id) }
        } else if entity.kind == .bookmark {
            let value = try entity.value(Bookmark.self)
            book.bookmarks.removeAll { $0.id == value.id }
            if !entity.deleted { book.bookmarks.append(value) }
        } else if entity.kind == .position, !entity.deleted {
            let value = try entity.value(SyncedPosition.self)
            book.position = value.locator; book.progress = value.progress; book.lastOpenedAt = value.lastOpenedAt
        } else if entity.kind == .chat {
            let value = try entity.value(ChatThread.self)
            var chats = book.conversationThreads.filter { $0.id != value.id }
            if !entity.deleted { chats.append(value) }
            book.chats = chats
            book.chatMessages = chats.first(where: { $0.id == book.activeChatID })?.messages
        }
        try check(token); try store.applyRemoteChanges([book])
    }

    private func blobs(in entity: SyncEntity) throws -> [BlobManifest] {
        guard !entity.deleted else { return [] }
        switch entity.kind {
        case .book: return try entity.value(SyncedBook.self).file.map { [$0] } ?? []
        case .annotation: return try entity.value(SyncedAnnotation.self).drawing.map { [$0] } ?? []
        default: return []
        }
    }

    private func materialize(_ blob: BlobManifest, to destination: URL, token: Int, scope: String, progress: ((Double) -> Void)? = nil) async throws {
        activeMaterializations += 1
        defer { activeMaterializations -= 1; purgeRemovedDownloads() }
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try await Task.detached { try BlobManifest.describe(destination) }.value
            if existing.hasSameContent(as: blob) { return }
        }
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        if let source = sourceFiles[blob.hash], FileManager.default.fileExists(atPath: source.path) {
            let directory = chunkDirectory
            try await Task.detached { try blob.stage(source, directory: directory) }.value
        }
        for (index, hash) in blob.chunks.enumerated() {
            try check(token)
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw SyncFailure.corruptAsset }
            let file = chunkDirectory.appendingPathComponent(hash)
            if !FileManager.default.fileExists(atPath: file.path) {
                try await transport.downloadChunk(hash: hash, to: file, scope: scope, blobHash: blob.assetKey)
            }
            let data = try Data(contentsOf: file)
            guard data.count <= BlobManifest.chunkSize, SyncCoding.hash(data) == hash else {
                try? FileManager.default.removeItem(at: file); throw SyncFailure.corruptAsset
            }
            progress?(Double(index + 1) / Double(max(1, blob.chunks.count)))
        }
        try check(token)
        let directory = chunkDirectory
        try await Task.detached { try blob.assemble(directory: directory, destination: destination) }.value
    }

    private func suspend(_ error: Error) throws {
        generation += 1; debounce?.cancel()
        preferences.mode = .off; journal.preferences = preferences
        journal.requiresAcknowledgement = true; status.requiresAcknowledgement = true
        status.phase = .unavailable; status.message = error.localizedDescription
        try persist()
        let transport = transport
        Task.detached { @MainActor in await transport.stop() }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyncCoding.encode(journal).write(to: journalURL, options: .atomic)
    }

    private func fail(_ error: Error) {
        status.phase = .error; status.message = error.localizedDescription
        if let failure = error as? SyncFailure {
            switch failure {
            case .unavailable, .googleSignInRequired, .googleNotConfigured, .accountChanged, .cloudReset:
                status.phase = .unavailable
            case .googleQuotaExceeded: status.phase = .storageFull
            case .googleRateLimited: status.phase = .offline
            default: break
            }
        }
        if let network = error as? URLError {
            status.phase = .offline
            logger.error("Network sync code \(network.errorCode, privacy: .public)")
        }
        if let drive = error as? DriveAPIError {
            logger.error("Drive sync HTTP \(drive.status, privacy: .public), code \(drive.reason, privacy: .public)")
            switch drive.reason {
            case "storageQuotaExceeded": status.phase = .storageFull
            case "invalidCredentials", "authError": status.phase = .unavailable
            case "rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded": status.phase = .offline
            default: if drive.status >= 500 { status.phase = .offline }
            }
            if drive.status == 401 { status.phase = .unavailable }
            if drive.status == 429 || drive.status >= 500 || ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"].contains(drive.reason) {
                retryFailures = min(9, retryFailures + 1)
                let exponential = min(3600, pow(2, Double(retryFailures)) * 5) + Double.random(in: 0...1)
                let delay = max(drive.retryAfter ?? 0, drive.reason == "dailyLimitExceeded" ? 3600 : exponential)
                retryAfter = Date().addingTimeInterval(delay)
                debounce?.cancel()
                debounce = Task.detached { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)); self?.syncNow() } catch {}
                }
            }
        }
        let ns = error as NSError
        if ns.domain == "CKErrorDomain" {
            logger.error("CloudKit sync code \(ns.code, privacy: .public)")
            switch ns.code {
            case 3, 4: status.phase = .offline
            case 9, 10: status.phase = .unavailable
            case 25: status.phase = .storageFull
            default: break
            }
            if let interval = (error as? CKError)?.retryAfterSeconds {
                retryAfter = Date().addingTimeInterval(interval)
            }
            if [3, 4, 6, 7, 23].contains(ns.code), preferences.mode != .off {
                debounce?.cancel()
                let delay = max(5, retryAfter.timeIntervalSinceNow)
                debounce = Task.detached { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)); self?.syncNow() } catch {}
                }
            }
        }
    }
}
