import CloudKit
import EpubKit
import Foundation
import PDFKit
import Security

/// Run only as the signed KodiReader-SyncSmoke development app. The two local
/// stores are isolated from Kodi Reader's normal library; cloud records use a
/// unique content identity. Successful runs tombstone only their own fixture.
@main
struct CloudKitSmoke {
    @MainActor static func main() async {
        let runID = UUID().uuidString
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KodiReaderCloudKitSmoke/\(runID)", isDirectory: true)
        var checks: [String] = []
        do {
            if CommandLine.arguments.contains("--fixture-check") {
                let bytes = makePDF(runID: runID)
                try require(bytes.count > BlobManifest.chunkSize, "PDF does not exercise multiple chunks")
                try require(PDFDocument(data: bytes)?.pageCount == 1, "PDF fixture is unreadable")
                log("PASS: synthetic PDF is readable and exceeds one 16 MiB chunk")
                return
            }
            guard Bundle.main.object(forInfoDictionaryKey: "KodiCloudKitSmoke") as? Bool == true else {
                throw failure("Use the signed KodiReader-SyncSmoke app, not an unsigned executable.")
            }
            try verifyDevelopmentSigning()
            if let option = CommandLine.arguments.firstIndex(of: "--cleanup-run"),
               CommandLine.arguments.indices.contains(option + 1) {
                try await cleanup(runID: CommandLine.arguments[option + 1])
                return
            }
            if let option = CommandLine.arguments.firstIndex(of: "--diagnose-run"),
               CommandLine.arguments.indices.contains(option + 1) {
                try await diagnose(runID: CommandLine.arguments[option + 1])
                return
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let a = LibraryStore(fileURL: root.appendingPathComponent("A/library.json"))
            let b = LibraryStore(fileURL: root.appendingPathComponent("B/library.json"))
            let ta = CloudKitSyncTransport(stagingDirectory: a.rootDirectory.appendingPathComponent("Sync/Payloads"), automaticallySync: false)
            let tb = CloudKitSyncTransport(stagingDirectory: b.rootDirectory.appendingPathComponent("Sync/Payloads"), automaticallySync: false)
            let sa = LibrarySyncCoordinator(store: a, transport: ta)
            let sb = LibrarySyncCoordinator(store: b, transport: tb)
            _ = try await ta.accountID()
            log("iCloud account is available")

            let bytes = makePDF(runID: runID)
            let source = root.appendingPathComponent("synthetic.pdf")
            try bytes.write(to: source, options: .atomic)
            let note = Annotation(locator: .pdfPage(0), text: "Synthetic passage", note: "Initial note", hasDrawing: true)
            let chat = ChatThread(title: "Synthetic history", messages: [
                ChatMessage(role: .user, text: "Synthetic question"),
                ChatMessage(role: .assistant, text: String(repeating: "Synthetic reply. ", count: 32_768))
            ])
            var record = BookRecord(id: "smoke-\(runID)", title: "Kodi CloudKit smoke \(runID)", author: "Synthetic fixture",
                documentKind: .pdf, importedRelativePath: LibraryStore.relativeImportedPath(for: "smoke-\(runID)", kind: .pdf),
                position: .pdfPage(0, totalProgression: 0.3), progress: 0.3, annotations: [note],
                bookmarks: [Bookmark(locator: .pdfPage(0), excerpt: "Synthetic bookmark")], chats: [chat])
            record.cloudIdentity = try BlobManifest.bookIdentity(file: source, kind: .pdf)
            _ = try a.importBook(from: source, bookID: record.id, kind: .pdf)
            let drawing = try JSONSerialization.data(withJSONObject: ["type": "excalidraw", "version": 2,
                "elements": [], "appState": [:], "files": [:], "fixturePadding": String(repeating: "x", count: 2 * 1024 * 1024)])
            try a.drawingStore.replaceScene(drawing, bookID: record.id, annotationID: note.id)
            a.upsert(record); try a.checkpoint()
            let identity = record.cloudIdentity!

            try await configure(sa, .init(mode: .notesOnly))
            try await configure(sb, .init(mode: .notesOnly))
            var received = try await waitForRecord(sb, store: b, identity: identity) {
                $0.annotations.first?.note == "Initial note" && $0.bookmarks.count == 1 && $0.progress == 0.3
            }
            try require(received.annotations.first?.note == "Initial note", "Notes did not arrive")
            try require(received.bookmarks.count == 1 && received.progress == 0.3, "Bookmark or reading position did not arrive")
            try require(b.existingImportedURL(for: received) == nil && received.cloudFile == nil, "Notes only transferred a book")
            try require(received.conversationThreads.isEmpty, "Disabled AI history transferred")
            try require(b.drawingStore.loadScene(bookID: received.id, annotationID: note.id) == drawing, "Drawing bytes differ")
            checks.append("Notes, bookmark, position, and 2 MiB drawing; no book or AI history")
            log(checks.last!)

            try await configure(sa, .init(mode: .booksAndNotes))
            try await sync(sb)
            received = try await waitForRecord(sb, store: b, identity: identity) { $0.cloudFile != nil }
            try require(b.existingImportedURL(for: received) == nil, "Metadata fetch downloaded the book")
            do { _ = try await sb.download(received); throw failure("Notes only allowed a book download") }
            catch SyncFailure.categoryDisabled {}
            try await configure(sb, .init(mode: .booksAndNotes))
            received = try requireRecord(b, identity)
            let download = try await sb.download(received)
            try require(try Data(contentsOf: download) == bytes, "17 MiB PDF bytes differ")
            checks.append("17 MiB PDF uploaded in chunks and downloaded only on request")
            log(checks.last!)

            try await configure(sa, .init(mode: .booksAndNotes, syncAIHistory: true))
            try await sync(sb)
            try require(try requireRecord(b, identity).conversationThreads.isEmpty, "AI history arrived before opt-in")
            try await configure(sb, .init(mode: .booksAndNotes, syncAIHistory: true))
            _ = try await waitForRecord(sb, store: b, identity: identity) {
                $0.conversationThreads.first?.messages == chat.messages
            }
            checks.append("Large conversation payload arrives only after independent AI opt-in")
            log(checks.last!)

            await sa.setPreferences(.init(mode: .off)); await sb.setPreferences(.init(mode: .off))
            try a.updateAndFlush(record.id) { $0.annotations[0].note = "Offline A"; $0.annotations[0].modifiedAt = Date() }
            received = try requireRecord(b, identity)
            try b.updateAndFlush(received.id) { $0.annotations[0].note = "Offline B"; $0.annotations[0].modifiedAt = Date() }
            try await configure(sa, .init(mode: .booksAndNotes, syncAIHistory: true))
            try await configure(sb, .init(mode: .booksAndNotes, syncAIHistory: true))
            try await sync(sa); try await sync(sb)
            let merged = try await waitForRecord(sb, store: b, identity: identity) {
                Set($0.annotations.compactMap(\.note)).isSuperset(of: ["Offline A", "Offline B"])
            }
            let versions = merged.annotations
            try require(Set(versions.compactMap(\.note)).isSuperset(of: ["Offline A", "Offline B"]), "Concurrent edits lost a version")
            try require(versions.contains { $0.recoveredFrom != nil }, "Conflict lacks a labeled recovery copy")
            checks.append("Concurrent offline notes preserve both versions")
            log(checks.last!)

            received = try requireRecord(b, identity)
            try sb.removeDownload(received)
            try require(b.existingImportedURL(for: try requireRecord(b, identity)) == nil, "Remove Download kept the file")
            try require(try requireRecord(b, identity).annotations.count == versions.count, "Remove Download removed notes")
            checks.append("Remove Download retains notes and cloud metadata")
            log(checks.last!)

            // No zone deletion or broad cleanup: only this run's exact book ID.
            let disposable = try requireRecord(a, identity)
            try require(disposable.id == record.id, "Fixture identity changed; cleanup stopped")
            try sa.deleteEverywhere(disposable); try await sync(sa); try await sync(sb)
            for _ in 0..<30 where b.record(cloudIdentity: identity) != nil {
                try await Task.sleep(for: .seconds(1)); try await sync(sb)
            }
            try require(b.record(cloudIdentity: identity) == nil, "Fixture deletion did not propagate")
            checks.append("Fixture deletion propagates and its binary assets are collected")
            await sa.setPreferences(.init(mode: .off)); await sb.setPreferences(.init(mode: .off))
            try report(root, runID: runID, checks: checks, error: nil)
            log("PASS: \(checks.count) live checks. Report: \(root.appendingPathComponent("result.json").path)")
        } catch {
            if FileManager.default.fileExists(atPath: root.path) {
                try? report(root, runID: runID, checks: checks, error: error.localizedDescription)
                log("FAIL: \(error.localizedDescription). Local fixture: \(root.path)")
            } else {
                log("FAIL: \(error.localizedDescription)")
            }
            exit(1)
        }
    }

    /// Delete only an exact, locally verified synthetic fixture left by a failed
    /// run. Never clear a record zone or the user's real library.
    @MainActor private static func cleanup(runID: String) async throws {
        guard UUID(uuidString: runID) != nil else { throw failure("Invalid fixture run ID") }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KodiReaderCloudKitSmoke/\(runID)", isDirectory: true)
        let store = LibraryStore(fileURL: root.appendingPathComponent("A/library.json"))
        guard let original = store.record(for: "smoke-\(runID)"), let identity = original.cloudIdentity,
              original.title == "Kodi CloudKit smoke \(runID)", original.author == "Synthetic fixture",
              identity == (try BlobManifest.bookIdentity(file: root.appendingPathComponent("synthetic.pdf"), kind: .pdf)) else {
            throw failure("Fixture identity could not be verified; cleanup stopped")
        }
        let db = CKContainer(identifier: CloudKitSyncTransport.containerIdentifier).privateCloudDatabase
        let id = CKRecord.ID(recordName: "book:\(identity):metadata", zoneID: .init(zoneName: CloudKitSyncTransport.libraryZone, ownerName: CKCurrentUserDefaultName))
        let remote: CKRecord
        do { remote = try await db.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { log("Fixture was never uploaded; no cloud cleanup needed"); return }
        guard let data = remote["payload"] as? Data else { throw failure("Missing fixture metadata") }
        var entity = try JSONDecoder().decode(SyncEntity.self, from: data)
        try require(entity.bookID == identity && entity.kind == .book && entity.id == id.recordName, "Server fixture identity differs")
        if !entity.deleted {
            let metadata = try JSONSerialization.jsonObject(with: entity.body) as? [String: Any]
            try require(metadata?["title"] as? String == original.title && metadata?["author"] as? String == original.author, "Server fixture metadata differs")
            entity.deleted = true; entity.body = Data(); entity.modifiedAt = Date(); entity.deviceID = "synthetic-fixture-cleanup"
            remote["deleted"] = true as NSNumber; remote["payload"] = try JSONEncoder().encode(entity) as NSData; remote["payloadBlob"] = nil
            _ = try await db.save(remote)
        }
        let transport = CloudKitSyncTransport(stagingDirectory: root.appendingPathComponent("Cleanup/Payloads"), automaticallySync: false)
        try await transport.collectDeletedAssets([entity])
        try JSONSerialization.data(withJSONObject: ["runID": runID, "cloudFixtureRemoved": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("cleanup-result.json"), options: .atomic)
        log("Removed verified synthetic fixture and its binary assets; tombstones retained")
    }

    /// Inspect only a previously generated fixture; log booleans and counts,
    /// never payload contents. This also exercises restoring an engine checkpoint.
    @MainActor private static func diagnose(runID: String) async throws {
        guard UUID(uuidString: runID) != nil else { throw failure("Invalid fixture run ID") }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KodiReaderCloudKitSmoke/\(runID)", isDirectory: true)
        let a = LibraryStore(fileURL: root.appendingPathComponent("A/library.json"))
        let b = LibraryStore(fileURL: root.appendingPathComponent("B/library.json"))
        guard let original = a.record(for: "smoke-\(runID)"), let identity = original.cloudIdentity,
              original.title == "Kodi CloudKit smoke \(runID)", original.author == "Synthetic fixture" else {
            throw failure("This is not a smoke fixture")
        }
        let db = CKContainer(identifier: CloudKitSyncTransport.containerIdentifier).privateCloudDatabase
        let subscriptions = try await db.allSubscriptions()
        log("Database subscriptions: \(subscriptions.count); configured library subscription exists: \(subscriptions.contains { $0.subscriptionID == "\(CloudKitSyncTransport.libraryZone)-subscription" })")
        let id = CKRecord.ID(recordName: "book:\(identity):metadata", zoneID: .init(zoneName: CloudKitSyncTransport.libraryZone, ownerName: CKCurrentUserDefaultName))
        let remote = try await db.record(for: id)
        guard let data = remote["payload"] as? Data else { throw failure("Missing inline fixture metadata") }
        let entity = try JSONDecoder().decode(SyncEntity.self, from: data)
        let metadata = try JSONSerialization.jsonObject(with: entity.body) as? [String: Any]
        log("Server book manifest present: \(metadata?["file"] != nil); client A: \(original.cloudFile != nil); client B: \(b.record(cloudIdentity: identity)?.cloudFile != nil)")
        let transport = CloudKitSyncTransport(stagingDirectory: b.rootDirectory.appendingPathComponent("Sync/Payloads"), automaticallySync: false)
        let sync = LibrarySyncCoordinator(store: b, transport: transport)
        let handler = transport.onEvent
        transport.onEvent = { event in
            if case .received(let entity, _) = event, entity.bookID == identity {
                log("Restarted B received fixture \(entity.kind.rawValue)")
            }
            try await handler?(event)
        }
        try await configure(sync, .init(mode: .notesOnly))
        log("Restarted B manifest present: \(b.record(cloudIdentity: identity)?.cloudFile != nil)")
        await sync.setPreferences(.init(mode: .off))
    }

    // Native engine fetches can overlap automatic fetches. The live test waits
    // for the expected entity, rather than assuming one manual fetch observes a
    // write completed by the other client a moment earlier. Production does not poll.
    @MainActor private static func waitForRecord(_ coordinator: LibrarySyncCoordinator,
        store: LibraryStore, identity: String, matching predicate: (BookRecord) -> Bool) async throws -> BookRecord {
        for _ in 0..<30 {
            if let record = store.record(cloudIdentity: identity), predicate(record) { return record }
            try await Task.sleep(for: .seconds(1)); try await sync(coordinator)
        }
        throw failure("Expected remote fixture change did not arrive within the test deadline")
    }

    @MainActor private static func sync(_ coordinator: LibrarySyncCoordinator) async throws {
        let previous = coordinator.status.lastSuccessfulSync
        coordinator.syncNow(); try await settle(coordinator, after: previous)
    }

    @MainActor private static func configure(_ coordinator: LibrarySyncCoordinator, _ preferences: SyncPreferences) async throws {
        let previous = coordinator.status.lastSuccessfulSync
        await coordinator.setPreferences(preferences)
        try await settle(coordinator, after: previous)
    }

    @MainActor private static func settle(_ coordinator: LibrarySyncCoordinator, after previous: Date?) async throws {
        // Preferences and Sync Now schedule their work on the main actor.
        // Wait for a new successful checkpoint rather than an old Synced label.
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<1_200 {
            if coordinator.status.phase == .synced, coordinator.status.lastSuccessfulSync != previous { return }
            if [.error, .unavailable, .offline, .storageFull].contains(coordinator.status.phase) {
                throw failure(coordinator.status.message ?? coordinator.status.phase.rawValue)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw failure("Sync timed out: \(coordinator.status.message ?? coordinator.status.phase.rawValue)")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    private static func requireRecord(_ store: LibraryStore, _ identity: String) throws -> BookRecord {
        guard let record = store.record(cloudIdentity: identity) else { throw failure("Fixture book did not arrive") }
        return record
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "KodiCloudKitSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    @MainActor private static func verifyDevelopmentSigning() throws {
        var code: SecCode?
        try require(SecCodeCopySelf([], &code) == errSecSuccess, "Cannot inspect the executable signature")
        guard let code else { throw failure("Missing executable signature") }
        var staticCode: SecStaticCode?
        try require(SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, "Cannot inspect the static executable signature")
        guard let staticCode else { throw failure("Missing static executable signature") }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        try require(SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess, "Cannot inspect signing entitlements")
        let values = information as? [String: Any]
        let entitlements = values?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        try require(values?[kSecCodeInfoTeamIdentifier as String] as? String == "3FJF74RW5L", "Use a development build signed by team 3FJF74RW5L")
        try require(entitlements?["com.apple.developer.icloud-container-environment"] as? String == "Development", "Refusing to test Production or an unsigned build")
        try require((entitlements?["com.apple.developer.icloud-container-identifiers"] as? [String])?.contains(CloudKitSyncTransport.containerIdentifier) == true, "Missing CloudKit container entitlement")
    }
    private static func log(_ message: String) {
        print(message); fflush(stdout)
    }
    private static func report(_ root: URL, runID: String, checks: [String], error: String?) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values: [String: Any] = ["runID": runID, "passed": error == nil, "checks": checks,
                                   "physicalMacCount": 1, "date": ISO8601DateFormatter().string(from: Date())]
        if let error { values["error"] = error }
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .atomic)
    }

    /// A valid, uncompressed PDF with a large comment in its page content stream.
    /// Offset calculations use bytes, so the resulting xref remains valid.
    private static func makePDF(runID: String) -> Data {
        var result = Data("%PDF-1.4\n% Kodi synthetic \(runID)\n".utf8)
        let content = "q 0 0 0 rg 20 20 100 20 re f Q\n%" + String(repeating: "x", count: 17 * 1024 * 1024) + "\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
        ]
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 5\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }
}
