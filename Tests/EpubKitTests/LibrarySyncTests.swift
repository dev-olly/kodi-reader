import CloudKit
import XCTest
@testable import EpubKit

private enum TestCallbackContext {
    @TaskLocal static var active = false
}

@MainActor
private final class TestCloud {
    var entities: [String: SyncEntity] = [:]
    var versions: [String: Data] = [:]
    var chunks: [String: Data] = [:]
    var chunkReferences = Set<String>()
    var revision = 0
}

@MainActor
private final class TestTransport: SyncTransport {
    var onEvent: ((SyncTransportEvent) async throws -> Void)?
    let cloud: TestCloud
    var account = "test-account"
    var aiEnabled = false
    var seen: [String: Data] = [:]
    var uploads = 0
    var downloads = 0
    var error: Error?
    var failDownloadAfter: Int?
    var callbackContexts: [Bool] = []
    init(_ cloud: TestCloud) { self.cloud = cloud }
    func accountID() async throws -> String { if let error { throw error }; return account }
    func configure(aiEnabled: Bool, states: [String: Data]) async throws { self.aiEnabled = aiEnabled }
    func fetch() async throws {
        callbackContexts.append(TestCallbackContext.active)
        for entity in cloud.entities.values.sorted(by: { $0.kind == .book && $1.kind != .book }) {
            if entity.kind == .chat && !aiEnabled { continue }
            let version = cloud.versions[entity.id]!
            if seen[entity.id] != version {
                try await onEvent?(.received(entity, serverFields: version)); seen[entity.id] = version
            }
        }
    }
    func send(_ entities: [SyncEntity], serverFields: [String: Data]) async throws {
        callbackContexts.append(TestCallbackContext.active)
        for entity in entities {
            XCTAssertTrue(entity.kind != .chat || aiEnabled)
            if let server = cloud.entities[entity.id], cloud.versions[entity.id] != serverFields[entity.id] {
                try await onEvent?(.received(server, serverFields: cloud.versions[entity.id]!))
            } else {
                cloud.revision += 1
                let version = Data(String(cloud.revision).utf8)
                cloud.entities[entity.id] = entity; cloud.versions[entity.id] = version; seen[entity.id] = version
                try await onEvent?(.acknowledged(entity, serverFields: version))
            }
        }
    }
    func uploadChunk(hash: String, file: URL, scope: String, bookID: String, blobHash: String, index: Int) async throws {
        uploads += 1; cloud.chunks[hash] = try Data(contentsOf: file)
        cloud.chunkReferences.insert("\(scope):\(blobHash):\(hash)")
    }
    func downloadChunk(hash: String, to file: URL, scope: String, blobHash: String) async throws {
        downloads += 1
        if let failDownloadAfter, downloads > failDownloadAfter { throw CKError(.networkFailure) }
        guard cloud.chunkReferences.contains("\(scope):\(blobHash):\(hash)") else { throw SyncFailure.corruptAsset }
        guard let data = cloud.chunks[hash] else { throw SyncFailure.corruptAsset }
        try data.write(to: file, options: .atomic)
    }
    func collectDeletedAssets(_ tombstones: [SyncEntity]) async throws {}
    func stop() async {}
}

@MainActor
final class LibrarySyncTests: XCTestCase {
    private var roots: [URL] = []
    func testNativeFetchScopeNeverIncludesAssetsOrDisabledHistory() {
        let library = CKRecordZone.ID(zoneName: CloudKitSyncTransport.libraryZone)
        let history = CKRecordZone.ID(zoneName: CloudKitSyncTransport.chatZone)
        let assets = CKRecordZone.ID(zoneName: CloudKitSyncTransport.assetZone)
        for enabled in [false, true] {
            let scope = CloudKitSyncTransport.metadataFetchScope(aiEnabled: enabled)
            XCTAssertTrue(scope.contains(library))
            XCTAssertEqual(scope.contains(history), enabled)
            XCTAssertFalse(scope.contains(assets))
            let narrower = CloudKitSyncTransport.metadataFetchScope(aiEnabled: enabled, requested: .zoneIDs([library, assets]))
            XCTAssertTrue(narrower.contains(library))
            XCTAssertFalse(narrower.contains(history))
            XCTAssertFalse(narrower.contains(assets))
        }
    }
    func testScheduledSyncDoesNotInheritTransportCallbackContext() async throws {
        let cloud = TestCloud(), local = try store()
        _ = try book(in: local, with: note())
        let transport = TestTransport(cloud), coordinator = LibrarySyncCoordinator(store: local, transport: transport)
        await TestCallbackContext.$active.withValue(true) {
            await coordinator.setPreferences(.init(mode: .notesOnly))
        }
        try await settle(coordinator)
        XCTAssertFalse(transport.callbackContexts.isEmpty)
        XCTAssertFalse(transport.callbackContexts.contains(true), "CloudKit forbids calling an engine from an inherited delegate context")
    }
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }
    private func store() throws -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kodi-sync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return LibraryStore(fileURL: root.appendingPathComponent("library.json"))
    }
    private func note(_ text: String = "first") -> Annotation {
        Annotation(locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [0], offset: 0)), text: "quote", note: text)
    }
    private func book(in store: LibraryStore, with note: Annotation? = nil, file: Data? = nil) throws -> BookRecord {
        var record = BookRecord(id: "local-book", title: "Book", author: "Author")
        record.annotations = note.map { [$0] } ?? []
        record.cloudIdentity = "epub-sha256:" + String(repeating: "a", count: 64)
        if let file {
            let source = store.rootDirectory.appendingPathComponent("source.epub")
            try file.write(to: source)
            record.cloudIdentity = try BlobManifest.bookIdentity(file: source, kind: .epub)
            _ = try store.importBook(from: source, bookID: record.id)
            record.importedRelativePath = LibraryStore.relativeImportedPath(for: record.id)
        }
        store.upsert(record); try store.checkpoint(); return record
    }
    private func settle(_ sync: LibrarySyncCoordinator) async throws {
        for _ in 0..<200 {
            await Task.yield()
            if sync.status.phase != .syncing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(sync.status.phase, .synced, sync.status.message ?? "")
    }
    private func run(_ sync: LibrarySyncCoordinator) async throws {
        sync.syncNow(); try await settle(sync)
    }
    func testNotesSyncAcrossTwoStoresWithoutBooksOrAITransfers() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        let note = note(), local = try book(in: a, with: note, file: Data("book".utf8))
        a.update(local.id) { $0.chats = [ChatThread(messages: [ChatMessage(role: .user, text: "private")])] }
        try a.checkpoint()
        let ta = TestTransport(cloud), tb = TestTransport(cloud)
        let sa = LibrarySyncCoordinator(store: a, transport: ta), sb = LibrarySyncCoordinator(store: b, transport: tb)
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        let received = try XCTUnwrap(b.record(cloudIdentity: local.cloudIdentity!))
        XCTAssertEqual(received.annotations.first?.note, "first")
        XCTAssertNil(received.chatMessages); XCTAssertNil(received.chats)
        XCTAssertNil(b.existingImportedURL(for: received)); XCTAssertEqual(ta.uploads, 0); XCTAssertEqual(tb.downloads, 0)
        XCTAssertFalse(cloud.entities.values.contains { $0.kind == .chat })
    }
    func testRenamedTitleSyncsToAnotherLibrary() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        let local = try book(in: a, with: note())
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud))
        let sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        try a.renameBook(local.id, to: "My reading copy")
        try await run(sa); try await run(sb)
        let received = try XCTUnwrap(b.record(cloudIdentity: local.cloudIdentity!))
        XCTAssertEqual(received.title, "My reading copy")
        XCTAssertEqual(received.annotations.map(\.id), local.annotations.map(\.id))
        XCTAssertEqual(received.cloudIdentity, local.cloudIdentity)
    }

    func testStoppedProviderKeepsItsJournalAndNeverUploadsToOldCloud() async throws {
        let originalCloud = TestCloud(), destinationCloud = TestCloud(), local = try store()
        let book = try book(in: local, with: note())
        let firstJournal = local.rootDirectory.appendingPathComponent("Sync/journal.json")
        let secondJournal = local.rootDirectory.appendingPathComponent("Sync/GoogleDrive/account/journal.json")
        let original = LibrarySyncCoordinator(store: local, transport: TestTransport(originalCloud),
                                              journalURL: firstJournal)
        await original.setPreferences(.init(mode: .notesOnly)); try await settle(original)
        await original.stop()
        local.update(book.id) { $0.annotations[0].note = "after switch" }
        try local.checkpoint()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(originalCloud.entities.values.contains {
            (try? $0.value(SyncedAnnotation.self).annotation.note) == "after switch"
        })
        let destination = LibrarySyncCoordinator(store: local, transport: TestTransport(destinationCloud),
                                                 journalURL: secondJournal)
        await destination.setPreferences(.init(mode: .notesOnly)); try await settle(destination)
        XCTAssertTrue(destinationCloud.entities.values.contains {
            (try? $0.value(SyncedAnnotation.self).annotation.note) == "after switch"
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstJournal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondJournal.path))
        XCTAssertFalse(originalCloud.entities.values.contains {
            (try? $0.value(SyncedAnnotation.self).annotation.note) == "after switch"
        })
    }
    func testFullLibraryDownloadsOnlyOnDemandAndCanRemoveDownload() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        let bytes = Data(repeating: 43, count: BlobManifest.chunkSize + 123)
        let local = try book(in: a, file: bytes)
        let ta = TestTransport(cloud), tb = TestTransport(cloud)
        let sa = LibrarySyncCoordinator(store: a, transport: ta), sb = LibrarySyncCoordinator(store: b, transport: tb)
        await sa.setPreferences(.init(mode: .booksAndNotes)); try await settle(sa)
        await sb.setPreferences(.init(mode: .booksAndNotes)); try await settle(sb)
        var received = try XCTUnwrap(b.record(cloudIdentity: local.cloudIdentity!))
        XCTAssertNil(b.existingImportedURL(for: received)); XCTAssertEqual(tb.downloads, 0)
        let file = try await sb.download(received)
        XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertEqual(tb.downloads, 2)
        received = try XCTUnwrap(b.record(for: received.id)); try sb.removeDownload(received)
        XCTAssertNil(b.existingImportedURL(for: received)); XCTAssertNotNil(b.record(for: received.id)?.cloudFile)
        for hash in received.cloudFile!.chunks {
            XCTAssertFalse(FileManager.default.fileExists(atPath: b.rootDirectory.appendingPathComponent("Sync/Chunks/" + hash).path))
        }
        XCTAssertFalse(cloud.entities.values.contains { $0.deleted })
    }
    func testNotesOnlyCannotDownloadPublishedBook() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        let local = try book(in: a, file: Data("book".utf8))
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .booksAndNotes)); try await settle(sa)
        let transport = TestTransport(cloud), sb = LibrarySyncCoordinator(store: b, transport: transport)
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        let record = try XCTUnwrap(b.record(cloudIdentity: local.cloudIdentity!))
        do { _ = try await sb.download(record); XCTFail("Must require full mode") } catch {}
        XCTAssertEqual(transport.downloads, 0); XCTAssertEqual(transport.uploads, 0)
        XCTAssertNotNil(try cloud.entities.values.first { $0.kind == .book }?.value(SyncedBook.self).file)
    }
    func testOptionalAIHistoryCanBeEnabledLater() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        let local = try book(in: a)
        a.update(local.id) { $0.chats = [ChatThread(messages: [ChatMessage(role: .user, text: "question")])] }
        try a.checkpoint()
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud)), sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        XCTAssertFalse(cloud.entities.values.contains { $0.kind == .chat })
        await sa.setPreferences(.init(mode: .notesOnly, syncAIHistory: true)); try await settle(sa)
        await sb.setPreferences(.init(mode: .notesOnly, syncAIHistory: true)); try await settle(sb)
        XCTAssertEqual(b.record(cloudIdentity: local.cloudIdentity!)?.chats?.first?.messages.first?.text, "question")
    }
    func testConcurrentNotesKeepDeterministicRecoveryCopy() throws {
        let original = note()
        func entity(_ note: Annotation) throws -> SyncEntity {
            SyncEntity(bookID: "book", kind: .annotation, key: note.id.uuidString, body: try SyncCoding.encode(SyncedAnnotation(annotation: note, drawing: nil)), deviceID: "a")
        }
        let base = try entity(original)
        var a = original, b = original; a.note = "left"; b.note = "right"
        let result = try SyncMerge.resolve(local: entity(a), remote: entity(b), ancestor: base)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(try result[0].value(SyncedAnnotation.self).annotation.note, "right")
        XCTAssertEqual(try result[1].value(SyncedAnnotation.self).annotation.note, "left")
        XCTAssertNotNil(try result[1].value(SyncedAnnotation.self).annotation.recoveredFrom)
        XCTAssertEqual(result[1].id, try SyncMerge.resolve(local: entity(a), remote: entity(b), ancestor: base)[1].id)
    }
    func testCompatibleAnnotationFieldsMerge() throws {
        let original = note()
        func entity(_ note: Annotation) throws -> SyncEntity {
            SyncEntity(bookID: "book", kind: .annotation, key: note.id.uuidString, body: try SyncCoding.encode(SyncedAnnotation(annotation: note, drawing: nil)), deviceID: "a")
        }
        var a = original, b = original; a.note = "changed"; b.color = .blue
        let result = try SyncMerge.resolve(local: entity(a), remote: entity(b), ancestor: entity(original))
        XCTAssertEqual(result.count, 1)
        let value = try result[0].value(SyncedAnnotation.self).annotation
        XCTAssertEqual(value.note, "changed"); XCTAssertEqual(value.color, .blue)
    }
    func testDeletedNoteKeepsConcurrentEditAsRecovery() throws {
        let original = note()
        let base = SyncEntity(bookID: "book", kind: .annotation, key: original.id.uuidString, body: try SyncCoding.encode(SyncedAnnotation(annotation: original, drawing: nil)), deviceID: "a")
        var local = base, remote = base; remote.deleted = true
        var changed = original; changed.note = "offline edit"
        local.body = try SyncCoding.encode(SyncedAnnotation(annotation: changed, drawing: nil))
        let result = try SyncMerge.resolve(local: local, remote: remote, ancestor: base)
        XCTAssertTrue(result[0].deleted); XCTAssertFalse(result[1].deleted)
        XCTAssertEqual(try result[1].value(SyncedAnnotation.self).annotation.note, "offline edit")
    }
    func testChatPrefixExtendsAndDivergenceRecovers() throws {
        let first = ChatMessage(role: .user, text: "question")
        var a = ChatThread(messages: [first]), b = a
        func entity(_ chat: ChatThread) throws -> SyncEntity {
            SyncEntity(bookID: "book", kind: .chat, key: chat.id.uuidString, body: try SyncCoding.encode(chat), deviceID: "a")
        }
        b.messages.append(ChatMessage(role: .assistant, text: "answer"))
        XCTAssertEqual(try SyncMerge.resolve(local: entity(a), remote: entity(b), ancestor: nil).count, 1)
        a.messages.append(ChatMessage(role: .assistant, text: "other"))
        XCTAssertEqual(try SyncMerge.resolve(local: entity(a), remote: entity(b), ancestor: nil).count, 2)
    }
    func testRemoteChangesAreDeferredWhileEditing() async throws {
        let cloud = TestCloud(), a = try store(), b = try store(), original = note()
        let local = try book(in: a, with: original)
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud)), sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        a.update(local.id) { $0.annotations[0].note = "remote" }; sa.checkpoint(); try await run(sa)
        sb.isEditing = { true }; sb.syncNow()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sb.status.phase, .syncing)
        XCTAssertEqual(b.record(cloudIdentity: local.cloudIdentity!)?.annotations.first?.note, "first")
        sb.isEditing = { false }; sb.resumeDeferredChanges(); try await settle(sb)
        XCTAssertEqual(b.record(cloudIdentity: local.cloudIdentity!)?.annotations.first?.note, "remote")
    }
    func testEditingOneEntityDoesNotBlockOtherBooks() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        let local = try book(in: a, with: note())
        var other = BookRecord(id: "second", title: "Second", author: "Author")
        other.cloudIdentity = "epub-sha256:" + String(repeating: "b", count: 64)
        a.upsert(other); try a.checkpoint()
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud))
        let sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        sb.isEntityEditing = { $0.bookID == local.cloudIdentity && $0.kind == .annotation }
        a.update(local.id) { $0.annotations[0].note = "remote" }
        a.update(other.id) { $0.title = "Updated second" }; sa.checkpoint(); try await run(sa)
        sb.syncNow(); try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(b.record(cloudIdentity: local.cloudIdentity!)?.annotations.first?.note, "first")
        XCTAssertEqual(b.record(cloudIdentity: other.cloudIdentity!)?.title, "Updated second")
        sb.isEntityEditing = { _ in false }; sb.resumeDeferredChanges(); try await settle(sb)
        XCTAssertEqual(b.record(cloudIdentity: local.cloudIdentity!)?.annotations.first?.note, "remote")
    }
    func testFirstEnableEnumeratesBeyondTwelveRecents() async throws {
        let cloud = TestCloud(), store = try store()
        for index in 0..<20 {
            var record = BookRecord(id: "book-\(index)", title: "Book \(index)", author: "Author")
            record.cloudIdentity = "epub-sha256:" + String(format: "%064x", index)
            store.upsert(record)
        }
        try store.checkpoint(); XCTAssertEqual(store.recentBooks().count, 12)
        let sync = LibrarySyncCoordinator(store: store, transport: TestTransport(cloud))
        await sync.setPreferences(.init(mode: .notesOnly)); try await settle(sync)
        XCTAssertEqual(cloud.entities.values.filter { $0.kind == .book }.count, 20)
    }
    func testAdHocBuildUsesLocalLibraryWithoutInitializingCloudKit() async throws {
        let store = try store(), local = try book(in: store, with: note())
        let transport = CloudKitSyncTransport(stagingDirectory: store.rootDirectory.appendingPathComponent("Payloads"), enabled: false)
        let sync = LibrarySyncCoordinator(store: store, transport: transport)
        XCTAssertEqual(sync.preferences.mode, .off)
        await sync.setPreferences(.init(mode: .notesOnly)); try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sync.status.phase, .unavailable)
        store.update(local.id) { $0.annotations[0].note = "still local" }; sync.checkpoint()
        await sync.setPreferences(.init(mode: .off))
        XCTAssertEqual(store.record(for: local.id)?.annotations.first?.note, "still local")
    }
    func testAccountSwitchPausesWithoutUploadingToNewAccount() async throws {
        let cloud = TestCloud(), store = try store(); _ = try book(in: store)
        let transport = TestTransport(cloud), sync = LibrarySyncCoordinator(store: store, transport: transport)
        await sync.setPreferences(.init(mode: .notesOnly)); try await settle(sync)
        let count = cloud.revision; transport.account = "other-account"; sync.syncNow()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(sync.preferences.mode, .off); XCTAssertTrue(sync.status.requiresAcknowledgement)
        XCTAssertEqual(cloud.revision, count); XCTAssertEqual(store.allBooks().count, 1)
    }
    func testCloudResetRequiresExplicitReenable() async throws {
        let store = try store(); _ = try book(in: store)
        let transport = TestTransport(TestCloud()), sync = LibrarySyncCoordinator(store: store, transport: transport)
        await sync.setPreferences(.init(mode: .notesOnly)); try await settle(sync)
        try await transport.onEvent?(.cloudReset)
        XCTAssertEqual(sync.preferences.mode, .off); XCTAssertTrue(sync.status.requiresAcknowledgement)
        await sync.setPreferences(.init(mode: .notesOnly))
        XCTAssertEqual(sync.preferences.mode, .off)
    }
    func testTombstonesSurviveRestartAndDoNotResurrectOfflineNotes() async throws {
        let cloud = TestCloud(), a = try store(), b = try store(), original = note()
        let local = try book(in: a, with: original)
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        let sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        a.update(local.id) { $0.annotations = [] }; sa.checkpoint(); try await run(sa)
        let restartedStore = LibraryStore(fileURL: b.rootDirectory.appendingPathComponent("library.json"))
        let restarted = LibrarySyncCoordinator(store: restartedStore, transport: TestTransport(cloud))
        try await run(restarted)
        XCTAssertEqual(restartedStore.record(cloudIdentity: local.cloudIdentity!)?.annotations.count, 0)
        XCTAssertTrue(cloud.entities.values.contains { $0.kind == .annotation && $0.deleted })
    }
    func testWholeBookDeletionKeepsConcurrentOfflineWorkInLocalRecoveryLibrary() async throws {
        let cloud = TestCloud(), a = try store(), b = try store(), original = note()
        let local = try book(in: a, with: original, file: Data("book".utf8))
        let other = try book(in: b, with: original, file: Data("book".utf8))
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud))
        let sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        b.update(other.id) { $0.annotations[0].note = "offline work" }; sb.checkpoint()
        try sa.deleteEverywhere(local); try await run(sa); try await run(sb)
        XCTAssertNil(b.record(cloudIdentity: local.cloudIdentity!))
        let recovered = try XCTUnwrap(b.allBooks().first)
        XCTAssertEqual(recovered.annotations.first?.note, "offline work")
        XCTAssertTrue(recovered.title.hasPrefix("Recovered version:"))
        XCTAssertNotNil(b.existingImportedURL(for: recovered))
        let restartedStore = LibraryStore(fileURL: b.rootDirectory.appendingPathComponent("library.json"))
        let restarted = LibrarySyncCoordinator(store: restartedStore, transport: TestTransport(cloud))
        try await run(restarted)
        XCTAssertEqual(restartedStore.allBooks().count, 1)
        XCTAssertNil(restartedStore.allBooks().first?.cloudIdentity)
        XCTAssertTrue(cloud.entities.values.filter { $0.kind == .book }.allSatisfy(\.deleted))
    }
    func testExplicitReimportUsesFreshAssetRootsAndKeepsTheManifestAfterRestart() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        let bytes = Data("book".utf8), local = try book(in: a, file: bytes)
        var time = Date()
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud), now: { time })
        await sa.setPreferences(.init(mode: .booksAndNotes)); try await settle(sa)
        try sa.deleteEverywhere(local); try await run(sa)
        time += 31
        _ = try book(in: a, file: bytes); sa.checkpoint(); try await run(sa)
        let restored = try XCTUnwrap(a.record(cloudIdentity: local.cloudIdentity!))
        XCTAssertNotNil(restored.cloudFile?.generation)
        let sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sb.setPreferences(.init(mode: .booksAndNotes)); try await settle(sb)
        let received = try XCTUnwrap(b.record(cloudIdentity: local.cloudIdentity!))
        let file = try await sb.download(received)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let restarted = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud))
        try await run(restarted)
        let manifest = try XCTUnwrap(a.record(cloudIdentity: local.cloudIdentity!)?.cloudFile)
        XCTAssertEqual(manifest.generation, restored.cloudFile?.generation)
        XCTAssertEqual(try cloud.entities.values.first { $0.kind == .book }?.value(SyncedBook.self).file?.generation, manifest.generation)
    }
    func testAccountReenableDoesNotPublishOldAccountsUndownloadedBookManifest() async throws {
        let oldCloud = TestCloud(), newCloud = TestCloud(), a = try store(), b = try store()
        let local = try book(in: a, file: Data("book".utf8))
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(oldCloud))
        await sa.setPreferences(.init(mode: .booksAndNotes)); try await settle(sa)
        let sb = LibrarySyncCoordinator(store: b, transport: TestTransport(oldCloud))
        await sb.setPreferences(.init(mode: .booksAndNotes)); try await settle(sb)
        XCTAssertNotNil(b.record(cloudIdentity: local.cloudIdentity!)?.cloudFile)
        let transport = TestTransport(newCloud); transport.account = "new-account"
        let changed = LibrarySyncCoordinator(store: b, transport: transport)
        changed.syncNow(); try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(changed.status.requiresAcknowledgement)
        await changed.setPreferences(.init(mode: .booksAndNotes), acknowledge: true); try await settle(changed)
        XCTAssertNil(b.record(cloudIdentity: local.cloudIdentity!)?.cloudFile)
        XCTAssertNil(try newCloud.entities.values.first { $0.kind == .book }?.value(SyncedBook.self).file)
        XCTAssertEqual(transport.uploads, 0)
    }
    func testPositionThrottleStillAppliesWhenNotesAreEdited() async throws {
        let cloud = TestCloud(), store = try store(), local = try book(in: store, with: note())
        var time = Date()
        let sync = LibrarySyncCoordinator(store: store, transport: TestTransport(cloud), now: { time })
        await sync.setPreferences(.init(mode: .notesOnly)); try await settle(sync)
        time += 10
        store.update(local.id) { $0.progress = 0.5; $0.annotations[0].note = "updated" }
        sync.checkpoint(); sync.syncNow()
        try await Task.sleep(for: .milliseconds(100))
        let position = try XCTUnwrap(cloud.entities.values.first { $0.kind == .position })
        XCTAssertEqual(try position.value(SyncedPosition.self).progress, 0)
        let note = try XCTUnwrap(cloud.entities.values.first { $0.kind == .annotation })
        XCTAssertEqual(try note.value(SyncedAnnotation.self).annotation.note, "updated")
        time += 21
        try await run(sync)
        XCTAssertEqual(try cloud.entities[position.id]?.value(SyncedPosition.self).progress, 0.5)
    }
    func testUnreadableLibraryCannotPublishDeletions() async throws {
        let cloud = TestCloud(), original = try store(); _ = try book(in: original, with: note())
        let first = LibrarySyncCoordinator(store: original, transport: TestTransport(cloud))
        await first.setPreferences(.init(mode: .notesOnly)); try await settle(first)
        let count = cloud.revision
        try Data("damaged JSON".utf8).write(to: original.rootDirectory.appendingPathComponent("library.json"), options: .atomic)
        let damaged = LibraryStore(fileURL: original.rootDirectory.appendingPathComponent("library.json"))
        let sync = LibrarySyncCoordinator(store: damaged, transport: TestTransport(cloud))
        sync.syncNow(); try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sync.status.phase, .error)
        XCTAssertEqual(cloud.revision, count)
        XCTAssertFalse(cloud.entities.values.contains(where: \.deleted))
    }
    func testEPUBIdentifierCollisionUsesSeparateContentIdentities() async throws {
        let root = try store().rootDirectory, url = URL(string: "https://example.com/edition")!
        let first = root.appendingPathComponent("first.epub"), second = root.appendingPathComponent("second.epub")
        try await ArticleEPUBBuilder.build(ArticleContent(title: "Edition", byline: "Author", sourceURL: url, contentHTML: "<p>First edition</p>"), to: first)
        try await ArticleEPUBBuilder.build(ArticleContent(title: "Edition", byline: "Author", sourceURL: url, contentHTML: "<p>Second edition</p>"), to: second)
        XCTAssertEqual(try EPUBBook(fileURL: first).bookID, try EPUBBook(fileURL: second).bookID)
        let firstID = try BlobManifest.bookIdentity(file: first, kind: .epub)
        let secondID = try BlobManifest.bookIdentity(file: second, kind: .epub)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(try EPUBBook(fileURL: second, knownBookID: secondID).bookID, secondID)
        let renamed = root.appendingPathComponent("renamed.epub")
        try FileManager.default.moveItem(at: first, to: renamed)
        XCTAssertEqual(try BlobManifest.bookIdentity(file: renamed, kind: .epub), firstID)
    }
    func testRemotePositionIsNotOverwrittenByFreshMacDefaults() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        let local = try book(in: a)
        a.update(local.id) {
            $0.progress = 0.72
            $0.position = Locator(spineIndex: 4, start: TextPosition(elementPath: [2], offset: 7))
        }
        try a.checkpoint()
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud)), sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        XCTAssertEqual(b.record(cloudIdentity: local.cloudIdentity!)?.progress, 0.72)
        XCTAssertEqual(b.record(cloudIdentity: local.cloudIdentity!)?.position?.spineIndex, 4)
        try await run(sa)
        XCTAssertEqual(a.record(for: local.id)?.progress, 0.72)
    }
    func testEditingCannotOverwriteDeferredRemoteNote() async throws {
        let cloud = TestCloud(), a = try store(), b = try store(), original = note()
        let local = try book(in: a, with: original)
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud)), sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        a.update(local.id) { $0.annotations[0].note = "remote" }; sa.checkpoint(); try await run(sa)
        let bID = try XCTUnwrap(b.record(cloudIdentity: local.cloudIdentity!)?.id)
        sb.isEditing = { true }
        b.update(bID) { $0.annotations[0].note = "local draft" }; sb.checkpoint(); sb.syncNow()
        for _ in 0..<100 { await Task.yield() }
        let serverNote = try XCTUnwrap(cloud.entities.values.first { $0.kind == .annotation && !$0.deleted })
        XCTAssertEqual(try serverNote.value(SyncedAnnotation.self).annotation.note, "remote")
        sb.isEditing = { false }; sb.resumeDeferredChanges()
        for _ in 0..<100 { await Task.yield() }
        sb.syncNow(); try await settle(sb)
        XCTAssertEqual(Set(b.record(for: bID)!.annotations.compactMap(\.note)), ["remote", "local draft"])
    }
    func testInterruptedDownloadResumesVerifiedChunks() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        let local = try book(in: a, file: Data(repeating: 71, count: BlobManifest.chunkSize + 80))
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .booksAndNotes)); try await settle(sa)
        let transport = TestTransport(cloud), sb = LibrarySyncCoordinator(store: b, transport: transport)
        await sb.setPreferences(.init(mode: .booksAndNotes)); try await settle(sb)
        let record = try XCTUnwrap(b.record(cloudIdentity: local.cloudIdentity!))
        transport.failDownloadAfter = 1
        do { _ = try await sb.download(record); XCTFail("Expected interruption") } catch {}
        XCTAssertNil(b.existingImportedURL(for: record))
        transport.failDownloadAfter = nil
        _ = try await sb.download(record)
        XCTAssertEqual(transport.downloads, 3)
        XCTAssertNotNil(b.existingImportedURL(for: record))
    }
    func testQuotaErrorKeepsPendingNotesAcrossRestart() async throws {
        let cloud = TestCloud(), a = try store(); let local = try book(in: a, with: note())
        let transport = TestTransport(cloud); transport.error = CKError(.quotaExceeded)
        let sa = LibrarySyncCoordinator(store: a, transport: transport)
        await sa.setPreferences(.init(mode: .notesOnly))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(sa.status.phase, .storageFull)
        XCTAssertEqual(a.record(for: local.id)?.annotations.first?.note, "first")
        let reopened = LibraryStore(fileURL: a.rootDirectory.appendingPathComponent("library.json"))
        let restarted = LibrarySyncCoordinator(store: reopened, transport: TestTransport(cloud))
        try await run(restarted)
        XCTAssertTrue(cloud.entities.values.contains { $0.kind == .annotation && !$0.deleted })
    }
    func testGoogleStorageFailureKeepsPendingNotes() async throws {
        let cloud = TestCloud(), local = try store()
        let record = try book(in: local, with: note())
        let transport = TestTransport(cloud)
        transport.error = DriveAPIError(status: 403, reason: "storageQuotaExceeded", retryAfter: nil)
        let coordinator = LibrarySyncCoordinator(store: local, transport: transport,
            journalURL: local.rootDirectory.appendingPathComponent("Sync/GoogleDrive/account/journal.json"))
        await coordinator.setPreferences(.init(mode: .notesOnly))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(coordinator.status.phase, .storageFull)
        XCTAssertEqual(local.record(for: record.id)?.annotations.first?.note, "first")
        XCTAssertTrue(cloud.entities.isEmpty)
        await coordinator.stop()
        let resumed = LibrarySyncCoordinator(store: local, transport: TestTransport(cloud),
            journalURL: local.rootDirectory.appendingPathComponent("Sync/GoogleDrive/account/journal.json"))
        try await run(resumed)
        XCTAssertTrue(cloud.entities.values.contains { $0.kind == .annotation && !$0.deleted })
    }
    func testCloudMetadataExcludesLocalSourcePaths() async throws {
        let cloud = TestCloud(), local = try store()
        let book = try book(in: local)
        local.update(book.id) { $0.sourceURL = URL(fileURLWithPath: "/Users/private/book.epub") }
        try local.checkpoint()
        let sync = LibrarySyncCoordinator(store: local, transport: TestTransport(cloud))
        await sync.setPreferences(.init(mode: .notesOnly)); try await settle(sync)
        let uploaded = try XCTUnwrap(cloud.entities.values.first { $0.kind == .book })
        XCTAssertNil(try uploaded.value(SyncedBook.self).sourceURL)
    }
    func testLargeAIHistoryRemainsOptional() async throws {
        let cloud = TestCloud(), a = try store(); let local = try book(in: a)
        a.update(local.id) { $0.chats = [ChatThread(messages: [ChatMessage(role: .assistant, text: String(repeating: "x", count: 2 * 1024 * 1024))])] }
        try a.checkpoint()
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        XCTAssertFalse(cloud.entities.values.contains { $0.kind == .chat })
        await sa.setPreferences(.init(mode: .notesOnly, syncAIHistory: true)); try await settle(sa)
        XCTAssertGreaterThan(cloud.entities.values.first { $0.kind == .chat }!.body.count, 1024 * 1024)
    }
    func testDrawingConflictPreservesBothScenes() async throws {
        let cloud = TestCloud(), a = try store(), b = try store()
        var original = note(); original.hasDrawing = true
        let local = try book(in: a, with: original)
        a.drawingStore.saveScene(Data("original".utf8), bookID: local.id, annotationID: original.id)
        a.drawingStore.flush(); try a.checkpoint()
        let sa = LibrarySyncCoordinator(store: a, transport: TestTransport(cloud)), sb = LibrarySyncCoordinator(store: b, transport: TestTransport(cloud))
        await sa.setPreferences(.init(mode: .notesOnly)); try await settle(sa)
        await sb.setPreferences(.init(mode: .notesOnly)); try await settle(sb)
        let bID = b.record(cloudIdentity: local.cloudIdentity!)!.id
        a.drawingStore.saveScene(Data("remote".utf8), bookID: local.id, annotationID: original.id)
        a.drawingStore.flush(); sa.checkpoint(); try await run(sa)
        b.drawingStore.saveScene(Data("local".utf8), bookID: bID, annotationID: original.id)
        b.drawingStore.flush(); sb.checkpoint(); try await run(sb)
        let copies = b.record(for: bID)!.annotations
        XCTAssertEqual(copies.count, 2)
        let scenes = copies.compactMap { b.drawingStore.loadScene(bookID: bID, annotationID: $0.id).flatMap { String(data: $0, encoding: .utf8) } }
        XCTAssertEqual(Set(scenes), ["remote", "local"])
    }
    func testHiddenBooksRetainNotesAndCompleteEnumeration() throws {
        let store = try store(), original = note(); let local = try book(in: store, with: original)
        store.hideFromRecents(local.id); try store.checkpoint()
        XCTAssertTrue(store.recentBooks().isEmpty); XCTAssertEqual(store.allBooks().count, 1)
        XCTAssertEqual(store.record(for: local.id)?.annotations.count, 1)
    }
    func testIdentityIgnoresFilenameAndDistinguishesContents() throws {
        let store = try store(), root = store.rootDirectory
        let a = root.appendingPathComponent("a.epub"), b = root.appendingPathComponent("renamed.epub")
        try Data("one".utf8).write(to: a); try Data("one".utf8).write(to: b)
        XCTAssertEqual(try BlobManifest.bookIdentity(file: a, kind: .epub), try BlobManifest.bookIdentity(file: b, kind: .epub))
        try Data("two".utf8).write(to: b)
        XCTAssertNotEqual(try BlobManifest.bookIdentity(file: a, kind: .epub), try BlobManifest.bookIdentity(file: b, kind: .epub))
    }
    func testCorruptChunkCannotReplaceExistingFile() throws {
        let store = try store(), root = store.rootDirectory
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try Data("new".utf8).write(to: source); try Data("existing".utf8).write(to: destination)
        let manifest = try BlobManifest.describe(source)
        let chunks = root.appendingPathComponent("chunks"); try manifest.stage(source, directory: chunks)
        try Data("corrupt".utf8).write(to: chunks.appendingPathComponent(manifest.chunks[0]))
        XCTAssertThrowsError(try manifest.assemble(directory: chunks, destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
    }
    func testMigrationBacksUpAndLegacyThreadIDsAreStable() throws {
        let store = try store(), messages = [ChatMessage(role: .user, text: "old")]
        var record = BookRecord(id: "old", title: "old", author: ""); record.chatMessages = messages
        store.upsert(record); try store.checkpoint()
        let file = store.rootDirectory.appendingPathComponent("library.json"), before = try Data(contentsOf: file)
        let migrated = LibraryStore(fileURL: file)
        XCTAssertEqual(try Data(contentsOf: store.rootDirectory.appendingPathComponent("library.before-icloud.json")), before)
        XCTAssertEqual(migrated.record(for: "old")?.chats?.first?.id, ChatThread.wrappingLegacyMessages(messages).id)
        XCTAssertEqual(ChatThread.wrappingLegacyMessages(messages).id, ChatThread.wrappingLegacyMessages(messages).id)
    }
}
