import CloudKit
import Foundation
import OSLog

/// Native private-database transport. Asset records never participate in engine fetches.
@MainActor
public final class CloudKitSyncTransport: SyncTransport, CKSyncEngineDelegate {
    public static let containerIdentifier = "iCloud.com.olly.KodiReader"
    public static let libraryZone = "KodiLibraryV1"
    public static let chatZone = "KodiAIHistoryV1"
    public static let assetZone = "KodiAssetsV1"
    public static let engineStateKey = "KodiPrivateV1"
    public var onEvent: ((SyncTransportEvent) async throws -> Void)?
    private let enabled: Bool
    private let automaticallySync: Bool
    private let staging: URL
    private var container: CKContainer?
    private var engine: CKSyncEngine?
    private var aiEnabled = false
    private var outgoing: [CKRecord.ID: CKRecord] = [:]
    private var sentEntities: [CKRecord.ID: SyncEntity] = [:]
    private var uploaded = Set<String>()
    private var failure: Error?
    private var safeToCheckpoint = true
    private var epoch = 0
    private let logger = Logger(subsystem: "com.olly.KodiReader", category: "iCloud")

    public init(stagingDirectory: URL, enabled: Bool = true, automaticallySync: Bool = true) {
        staging = stagingDirectory; self.enabled = enabled; self.automaticallySync = automaticallySync
    }

    private func database() throws -> CKDatabase {
        guard enabled else { throw SyncFailure.unavailable }
        if container == nil { container = CKContainer(identifier: Self.containerIdentifier) }
        return container!.privateCloudDatabase
    }

    public func accountID() async throws -> String {
        _ = try database()
        guard try await container!.accountStatus() == .available else { throw SyncFailure.unavailable }
        return try await container!.userRecordID().recordName
    }

    public func configure(aiEnabled: Bool, states: [String: Data]) async throws {
        let db = try database()
        if failure != nil || self.aiEnabled != aiEnabled { await stop() }
        failure = nil; safeToCheckpoint = true
        self.aiEnabled = aiEnabled
        guard engine == nil else { return }
        let token = epoch
        for name in [Self.libraryZone] + (aiEnabled ? [Self.chatZone] : []) {
            let id = zoneID(name)
            let previouslyKnown = states["known:\(name)"] != nil || states[name] != nil
                || (name == Self.libraryZone && states[Self.engineStateKey] != nil)
            if previouslyKnown {
                do { _ = try await db.recordZone(for: id) }
                catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                    try await onEvent?(.cloudReset); throw SyncFailure.cloudReset
                }
            } else { _ = try await db.save(CKRecordZone(zoneID: id)) }
            try check(token)
            try await onEvent?(.state(zone: "known:\(name)", data: Data([1])))
        }
        // Apple permits one engine per database in Production. AI history stays
        // in its own zone, excluded from both scheduled and manual operations
        // until enabled. Old per-zone checkpoints are replaced by a fresh fetch;
        // durable entities, ancestors and pending edits remain in the journal.
        let state = try states[Self.engineStateKey].map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var config = CKSyncEngine.Configuration(database: db, stateSerialization: state, delegate: self)
        config.automaticallySync = automaticallySync
        engine = CKSyncEngine(config)
        if !aiEnabled, let engine {
            let disabled = engine.state.pendingRecordZoneChanges.filter { change in
                switch change {
                case .saveRecord(let id), .deleteRecord(let id): return id.zoneID.zoneName == Self.chatZone
                @unknown default: return false
                }
            }
            engine.state.remove(pendingRecordZoneChanges: disabled)
        }
    }

    public func fetch() async throws {
        try await engine?.fetchChanges(.init(scope: fetchScope))
        if let failure { throw failure }
    }

    public func send(_ entities: [SyncEntity], serverFields: [String: Data]) async throws {
        let token = epoch
        for entity in entities {
            try Task.checkCancellation()
            guard token == epoch else { throw CancellationError() }
            let name = entity.kind == .chat ? Self.chatZone : Self.libraryZone
            guard let engine, allowedZone(name) else { continue }
            let id = CKRecord.ID(recordName: entity.id, zoneID: zoneID(name))
            let record = try await makeRecord(entity, id: id, fields: serverFields[entity.id])
            guard token == epoch else { throw CancellationError() }
            outgoing[id] = record; sentEntities[id] = entity
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        }
        try await engine?.sendChanges(.init(scope: .zoneIDs(enabledZones.map(zoneID))))
        if let failure { throw failure }
    }

    private func makeRecord(_ entity: SyncEntity, id: CKRecord.ID, fields: Data?) async throws -> CKRecord {
        let record: CKRecord
        if let fields {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: fields)
            decoder.requiresSecureCoding = true
            guard let decoded = CKRecord(coder: decoder), decoded.recordID == id else { throw SyncFailure.unsupportedSchema }
            decoder.finishDecoding()
            record = decoded
        } else { record = CKRecord(recordType: "KodiEntity", recordID: id) }
        record["schemaVersion"] = 1 as NSNumber
        record["bookID"] = entity.bookID as NSString
        record["kind"] = entity.kind.rawValue as NSString
        record["deleted"] = entity.deleted as NSNumber
        let data = try await Task.detached { try SyncCoding.encode(entity) }.value
        if data.count <= 256 * 1024 {
            record["payload"] = data as NSData; record["payloadBlob"] = nil
        } else {
            let root = payloadDirectory(bookID: entity.bookID, entityID: entity.id)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent(SyncCoding.hash(data))
            try data.write(to: file, options: .atomic)
            let directory = root.appendingPathComponent("Chunks", isDirectory: true)
            let manifest = try await Task.detached {
                let manifest = try BlobManifest.describe(file)
                try manifest.stage(file, directory: directory)
                return manifest
            }.value
            for (index, hash) in manifest.chunks.enumerated() {
                try Task.checkCancellation()
                try await uploadChunk(hash: hash, file: directory.appendingPathComponent(hash), scope: entity.id, bookID: entity.bookID, blobHash: manifest.hash, index: index)
            }
            record["payload"] = nil; record["payloadBlob"] = try SyncCoding.encode(manifest) as NSData
        }
        return record
    }

    private func decode(_ record: CKRecord) async throws -> SyncEntity {
        guard (record["schemaVersion"] as? NSNumber)?.intValue == 1, let bookID = record["bookID"] as? String else { throw SyncFailure.unsupportedSchema }
        let data: Data
        if let inline = record["payload"] as? Data { data = inline }
        else if let reference = record["payloadBlob"] as? Data {
            let manifest = try JSONDecoder().decode(BlobManifest.self, from: reference)
            guard validHash(manifest.hash) else { throw SyncFailure.corruptAsset }
            let root = payloadDirectory(bookID: bookID, entityID: record.recordID.recordName)
            let directory = root.appendingPathComponent("Chunks", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for hash in manifest.chunks {
                try Task.checkCancellation()
                let file = directory.appendingPathComponent(hash)
                if !FileManager.default.fileExists(atPath: file.path) { try await downloadChunk(hash: hash, to: file, scope: record.recordID.recordName, blobHash: manifest.hash) }
            }
            let file = root.appendingPathComponent(manifest.hash)
            try await Task.detached { try manifest.assemble(directory: directory, destination: file) }.value
            data = try Data(contentsOf: file)
        }
        else { throw SyncFailure.unsupportedSchema }
        let entity = try await Task.detached { try JSONDecoder().decode(SyncEntity.self, from: data) }.value
        guard entity.id == record.recordID.recordName, entity.bookID == bookID,
              entity.kind.rawValue == record["kind"] as? String,
              entity.deleted == (record["deleted"] as? NSNumber)?.boolValue else { throw SyncFailure.unsupportedSchema }
        return entity
    }

    private func fields(_ record: CKRecord) -> Data {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder); encoder.finishEncoding()
        return encoder.encodedData
    }

    public func uploadChunk(hash: String, file: URL, scope: String, bookID: String, blobHash: String, index: Int) async throws {
        let token = epoch
        try check(token)
        guard validHash(hash) else { throw SyncFailure.corruptAsset }
        let rootName = SyncCoding.hash(Data("\(scope):\(blobHash)".utf8))
        let chunkName = SyncCoding.hash(Data("\(rootName):\(hash)".utf8))
        if uploaded.contains(chunkName) { return }
        let db = try database()
        let zone = zoneID(Self.assetZone)
        _ = try await db.save(CKRecordZone(zoneID: zone))
        try check(token)
        let rootID = CKRecord.ID(recordName: "root-" + rootName, zoneID: zone)
        let groupID = CKRecord.ID(recordName: "group-\(rootName)-\(index / 750)", zoneID: zone)
        let root = CKRecord(recordType: "KodiAssetRoot", recordID: rootID)
        root["bookID"] = bookID as NSString; root["scope"] = scope as NSString
        let group = CKRecord(recordType: "KodiAssetGroup", recordID: groupID)
        group["parent"] = CKRecord.Reference(recordID: rootID, action: .deleteSelf)
        for owner in [root, group] {
            try check(token)
            do { _ = try await db.save(owner) }
            catch let error as CKError where error.code == .serverRecordChanged {}
            try check(token)
        }
        let id = CKRecord.ID(recordName: chunkName, zoneID: zone)
        do {
            let results = try await db.records(for: [id], desiredKeys: ["hash"])
            try check(token)
            if let result = results[id] {
                do {
                    let record = try result.get()
                    guard record["hash"] as? String == hash else { throw SyncFailure.corruptAsset }
                    uploaded.insert(chunkName); return
                } catch let error as CKError where error.code == .unknownItem {}
            }
        } catch let error as CKError where error.code == .unknownItem {}
        let data = try Data(contentsOf: file)
        guard data.count <= BlobManifest.chunkSize, SyncCoding.hash(data) == hash else { throw SyncFailure.corruptAsset }
        let record = CKRecord(recordType: "KodiChunk", recordID: id)
        record["hash"] = hash as NSString; record["file"] = CKAsset(fileURL: file)
        record["parent"] = CKRecord.Reference(recordID: groupID, action: .deleteSelf)
        try check(token)
        do { _ = try await db.save(record) }
        catch let error as CKError where error.code == .serverRecordChanged {
            guard error.serverRecord?["hash"] as? String == hash else { throw error }
        }
        try check(token)
        uploaded.insert(chunkName)
    }

    public func downloadChunk(hash: String, to file: URL, scope: String, blobHash: String) async throws {
        let token = epoch
        guard validHash(hash) else { throw SyncFailure.corruptAsset }
        let rootName = SyncCoding.hash(Data("\(scope):\(blobHash)".utf8))
        let chunkName = SyncCoding.hash(Data("\(rootName):\(hash)".utf8))
        let record = try await database().record(for: CKRecord.ID(recordName: chunkName, zoneID: zoneID(Self.assetZone)))
        try check(token)
        guard record["hash"] as? String == hash, let source = (record["file"] as? CKAsset)?.fileURL else {
            throw SyncFailure.corruptAsset
        }
        let data = try Data(contentsOf: source)
        guard data.count <= BlobManifest.chunkSize, SyncCoding.hash(data) == hash else { throw SyncFailure.corruptAsset }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    public func collectDeletedAssets(_ tombstones: [SyncEntity]) async throws {
        guard !tombstones.isEmpty else { return }
        let token = epoch
        let db = try database()
        var confirmed: [SyncEntity] = []
        for entity in tombstones {
            try check(token)
            let zone = entity.kind == .chat ? Self.chatZone : Self.libraryZone
            let id = CKRecord.ID(recordName: entity.id, zoneID: zoneID(zone))
            let result = try await db.records(for: [id], desiredKeys: ["deleted"])
            try check(token)
            if let record = try result[id]?.get(), (record["deleted"] as? NSNumber)?.boolValue == true { confirmed.append(entity) }
        }
        let deletedBooks = Set(confirmed.filter { $0.kind == .book }.map(\.bookID))
        // Delete-everywhere includes history that this Mac has never opted to download.
        // Read identifiers only, and replace those child records with content-free tombstones.
        if !deletedBooks.isEmpty {
            for zone in [Self.libraryZone, Self.chatZone] {
                let children = try await scan(zone: zone, keys: ["bookID", "kind", "deleted"])
                try check(token)
                for child in children {
                    guard let bookID = child["bookID"] as? String, deletedBooks.contains(bookID),
                          let kind = (child["kind"] as? String).flatMap(SyncEntityKind.init(rawValue:)), kind != .book,
                          (child["deleted"] as? NSNumber)?.boolValue != true,
                          let key = child.recordID.recordName.split(separator: ":").last else { continue }
                    let deletion = SyncEntity(bookID: bookID, kind: kind, key: String(key), body: Data(), deviceID: "cloud-cleanup", deleted: true)
                    child["schemaVersion"] = 1 as NSNumber; child["deleted"] = true as NSNumber
                    child["payload"] = try SyncCoding.encode(deletion) as NSData; child["payloadBlob"] = nil
                    try check(token)
                    do { _ = try await db.save(child) }
                    catch let error as CKError where error.code == .serverRecordChanged { continue }
                }
            }
        }
        let scopes = Set(confirmed.map(\.id))
        let roots = try await scan(zone: Self.assetZone, keys: ["scope", "bookID"])
        for root in roots where root.recordType == "KodiAssetRoot" {
            try Task.checkCancellation()
            guard token == epoch else { throw CancellationError() }
            let scope = root["scope"] as? String ?? ""
            let book = root["bookID"] as? String ?? ""
            guard scopes.contains(scope) || deletedBooks.contains(book) else { continue }
            let guardScope = deletedBooks.contains(book) ? "book:\(book):metadata" : scope
            let guardZone = guardScope.hasPrefix("chat:") ? Self.chatZone : Self.libraryZone
            let result = try await db.records(for: [.init(recordName: guardScope, zoneID: zoneID(guardZone))], desiredKeys: ["deleted"])
            guard let record = try result.values.first?.get(), (record["deleted"] as? NSNumber)?.boolValue == true else { continue }
            try check(token)
            // References within the asset zone cascade through groups of at most 750 chunks.
            _ = try await db.deleteRecord(withID: root.recordID)
        }
        uploaded = []
        for entity in confirmed {
            let directory = entity.kind == .book
                ? staging.appendingPathComponent(SyncCoding.hash(Data(entity.bookID.utf8)), isDirectory: true)
                : payloadDirectory(bookID: entity.bookID, entityID: entity.id)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func scan(zone: String, keys: [String]) async throws -> [CKRecord] {
        var token: CKServerChangeToken?, records: [CKRecord] = []
        do {
            repeat {
                let changes = try await database().recordZoneChanges(inZoneWith: zoneID(zone), since: token, desiredKeys: keys)
                for value in changes.modificationResultsByID.values { records.append(try value.get().record) }
                token = changes.changeToken
                if !changes.moreComing { break }
            } while true
        } catch let error as CKError where error.code == .zoneNotFound { return [] }
        return records
    }

    public func stop() async {
        epoch += 1
        let previous = engine
        engine = nil; outgoing = [:]; sentEntities = [:]; uploaded = []
        await previous?.cancelOperations()
    }

    public func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = Self.metadataFetchScope(aiEnabled: aiEnabled, requested: context.options.scope)
        return options
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === syncEngine else { return nil }
        let records = outgoing.values.filter { allowedZone($0.recordID.zoneID.zoneName) && context.options.scope.contains($0.recordID) }
        guard !records.isEmpty else { return nil }
        return .init(recordsToSave: Array(records.prefix(100)), atomicByZone: false)
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard engine === syncEngine else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                if safeToCheckpoint { try await onEvent?(.state(zone: Self.engineStateKey, data: JSONEncoder().encode(update.stateSerialization))) }
            case .accountChange(let change):
                switch change.changeType {
                case .signIn: break // Explicit account checks also detect a switch while the app was closed.
                default: try await onEvent?(.accountChanged)
                }
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { allowedZone($0.zoneID.zoneName) }) { try await onEvent?(.cloudReset) }
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications where allowedZone(modification.record.recordID.zoneID.zoneName) {
                    try await onEvent?(.received(try await decode(modification.record), serverFields: fields(modification.record)))
                }
                // We retain tombstones. Hard deletions signify data removed outside this app.
                if changes.deletions.contains(where: { allowedZone($0.recordID.zoneID.zoneName) }) { try await onEvent?(.cloudReset) }
                logger.info("Fetched \(changes.modifications.count) sync records")
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords {
                    if let entity = sentEntities.removeValue(forKey: record.recordID) {
                        try await onEvent?(.acknowledged(entity, serverFields: fields(record)))
                        outgoing[record.recordID] = nil
                    }
                }
                for failed in changes.failedRecordSaves {
                    outgoing[failed.record.recordID] = nil; sentEntities[failed.record.recordID] = nil
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    if failed.error.code == .serverRecordChanged, let server = failed.error.serverRecord {
                        try await onEvent?(.received(try await decode(server), serverFields: fields(server)))
                    } else { throw failed.error }
                }
                logger.info("Saved \(changes.savedRecords.count) sync records")
            case .didFetchRecordZoneChanges(let fetched):
                if let error = fetched.error { throw error }
            case .sentDatabaseChanges(let sent):
                if let failed = sent.failedZoneSaves.first { throw failed.error }
            default: break
            }
        } catch {
            failure = error; safeToCheckpoint = false
            logger.error("Sync event failed, code \((error as NSError).code)")
            try? await onEvent?(.failed(error))
        }
    }

    private func zoneID(_ name: String) -> CKRecordZone.ID { .init(zoneName: name, ownerName: CKCurrentUserDefaultName) }
    private var enabledZones: [String] { [Self.libraryZone] + (aiEnabled ? [Self.chatZone] : []) }
    private func allowedZone(_ name: String) -> Bool { enabledZones.contains(name) }
    private var fetchScope: CKSyncEngine.FetchChangesOptions.Scope { Self.metadataFetchScope(aiEnabled: aiEnabled) }
    static func metadataFetchScope(aiEnabled: Bool, requested: CKSyncEngine.FetchChangesOptions.Scope = .all) -> CKSyncEngine.FetchChangesOptions.Scope {
        let zones = ([libraryZone] + (aiEnabled ? [chatZone] : [])).map {
            CKRecordZone.ID(zoneName: $0, ownerName: CKCurrentUserDefaultName)
        }
        return .zoneIDs(zones.filter { requested.contains($0) })
    }
    private func payloadDirectory(bookID: String, entityID: String) -> URL {
        staging.appendingPathComponent(SyncCoding.hash(Data(bookID.utf8)), isDirectory: true)
            .appendingPathComponent(SyncCoding.hash(Data(entityID.utf8)), isDirectory: true)
    }
    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == epoch else { throw CancellationError() }
    }
    private func validHash(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy { $0.isHexDigit } }
}
