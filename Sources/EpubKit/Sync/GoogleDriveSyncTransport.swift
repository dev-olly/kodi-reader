import Foundation

/// Provides a Drive access token without coupling library sync to the app's UI or Keychain.
@MainActor public protocol GoogleDriveCredentialProvider: AnyObject {
    func accessToken() async throws -> String
}

public struct DriveAPIError: LocalizedError {
    public let status: Int
    public let reason: String
    public let retryAfter: TimeInterval?
    public var errorDescription: String? {
        switch reason {
        case "storageQuotaExceeded": "Google Drive storage is full. Local changes are queued."
        case "rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded": "Google Drive is busy. Kodi will retry later."
        case "invalidCredentials", "authError": "Connect Google Drive again to resume sync."
        default: "Google Drive sync failed (HTTP \(status), \(reason))."
        }
    }
}

/// Drive appDataFolder transport. Metadata is an append-only set of revisions;
/// a writer never replaces another device's note, drawing, or conversation.
@MainActor
public final class GoogleDriveSyncTransport: SyncTransport {
    public var onEvent: ((SyncTransportEvent) async throws -> Void)?
    public private(set) var accountEmail: String?
    private let credentials: any GoogleDriveCredentialProvider
    private let session: URLSession
    private let staging: URL
    private var enabledAI = false
    private var index: [String: [Revision]] = [:]
    private var cursor: String?
    private var markerID: String?
    private var lastDelivered: [String: [String]] = [:]
    private var needsMerge: [String: SyncEntity] = [:]
    private var assetFiles: [String: String] = [:]
    private var initialized = false
    private var epoch = 0

    private struct FileInfo: Decodable {
        var id: String
        var name: String?
        var appProperties: [String: String]?
        var trashed: Bool?
    }
    private struct FileList: Decodable { var files: [FileInfo]; var nextPageToken: String? }
    private struct Change: Decodable { var fileId: String?; var removed: Bool?; var file: FileInfo? }
    private struct ChangeList: Decodable {
        var changes: [Change]
        var nextPageToken: String?
        var newStartPageToken: String?
    }
    private struct StartToken: Decodable { var startPageToken: String }
    private struct About: Decodable {
        struct User: Decodable { var permissionId: String; var emailAddress: String? }
        var user: User
    }
    private struct Revision: Codable {
        var fileID: String
        var logicalID: String
        var entity: SyncEntity
        var parents: [String]
        var ancestor: SyncEntity?
    }
    private struct Envelope: Codable {
        var schema = 1
        var logicalID: String
        var entity: SyncEntity
        var parents: [String]
        var ancestor: SyncEntity?
        var payload: BlobManifest?
    }
    private struct ServerFields: Codable {
        var entity: SyncEntity
        var heads: [String]
    }

    public init(credentials: any GoogleDriveCredentialProvider, stagingDirectory: URL,
                session: URLSession = .shared) {
        self.credentials = credentials
        self.staging = stagingDirectory
        self.session = session
    }

    public func accountID() async throws -> String {
        let about: About = try await getJSON("https://www.googleapis.com/drive/v3/about?fields=user(permissionId,emailAddress)")
        accountEmail = about.user.emailAddress
        return about.user.permissionId
    }

    public func configure(aiEnabled: Bool, states: [String: Data]) async throws {
        if !initialized {
            index = (try? states["drive.index"].map { try JSONDecoder().decode([String: [Revision]].self, from: $0) }) ?? [:]
            cursor = states["drive.cursor"].flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
            markerID = states["drive.marker"].flatMap { String(data: $0, encoding: .utf8) }
            lastDelivered = (try? states["drive.delivered"].map { try JSONDecoder().decode([String: [String]].self, from: $0) }) ?? [:]
            enabledAI = states["drive.aiEnabled"] == Data("1".utf8)
            initialized = true
        }
        if let markerID {
            do {
                let marker = try await fileInfo(markerID)
                if marker.trashed == true { try await onEvent?(.cloudReset); throw SyncFailure.cloudReset }
            }
            catch let error as DriveAPIError where error.status == 404 {
                try await onEvent?(.cloudReset)
                throw SyncFailure.cloudReset
            }
        } else {
            let files = try await listFiles(query: "name = 'kodi-v1-marker'")
            if let existing = files.first { markerID = existing.id }
            else {
                let created = try await createFile(name: "kodi-v1-marker", type: "marker", data: Data("1".utf8))
                markerID = created.id
            }
            try await saveState("drive.marker", Data(markerID!.utf8))
        }
        if aiEnabled && !enabledAI {
            cursor = nil; index.removeAll(); lastDelivered.removeAll()
            // Persist the rescan requirement before remembering the enabled
            // category, so a crash cannot skip messages that arrived while off.
            try await saveState("drive.cursor", Data())
        }
        if aiEnabled != enabledAI { try await saveState("drive.aiEnabled", Data((aiEnabled ? "1" : "0").utf8)) }
        enabledAI = aiEnabled
    }

    public func fetch() async throws {
        try await fetch(allowExpiredCursorRecovery: true)
    }

    private func fetch(allowExpiredCursorRecovery: Bool) async throws {
        let token = epoch
        if cursor == nil {
            let start: StartToken = try await getJSON("https://www.googleapis.com/drive/v3/changes/startPageToken?spaces=appDataFolder")
            try check(token)
            index.removeAll(); assetFiles.removeAll()
            let files = try await listFiles(query: "'appDataFolder' in parents")
            for file in files { try await ingest(file, token: token) }
            cursor = start.startPageToken
        }
        var page = cursor!
        do {
            while true {
                let url = "https://www.googleapis.com/drive/v3/changes?spaces=appDataFolder&includeRemoved=true&pageSize=1000&fields=nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,appProperties,trashed))&pageToken=\(encoded(page))"
                let batch: ChangeList = try await getJSON(url)
                try check(token)
                for change in batch.changes {
                    if change.removed == true, let id = change.fileId {
                        if index.values.contains(where: { $0.contains(where: { $0.fileID == id }) }) {
                            try await onEvent?(.cloudReset)
                            throw SyncFailure.cloudReset
                        }
                        for key in index.keys { index[key]?.removeAll { $0.fileID == id } }
                        assetFiles = assetFiles.filter { $0.value != id }
                        if id == markerID { try await onEvent?(.cloudReset); throw SyncFailure.cloudReset }
                    } else if let file = change.file {
                        if file.trashed == true {
                            if file.id == markerID || index.values.contains(where: { $0.contains(where: { $0.fileID == file.id }) }) {
                                try await onEvent?(.cloudReset)
                                throw SyncFailure.cloudReset
                            }
                            assetFiles = assetFiles.filter { $0.value != file.id }
                        } else { try await ingest(file, token: token) }
                    }
                }
                if let next = batch.nextPageToken { page = next; continue }
                cursor = batch.newStartPageToken ?? page
                break
            }
        } catch let error as DriveAPIError where error.status == 410 && allowExpiredCursorRecovery {
            cursor = nil; index.removeAll(); assetFiles.removeAll(); lastDelivered.removeAll()
            try await fetch(allowExpiredCursorRecovery: false)
            return
        }
        try await deliverHeads(token: token)
        // The callback has persisted every applied entity before advancing the cursor.
        try await saveState("drive.index", try SyncCoding.encode(index))
        try await saveState("drive.delivered", try SyncCoding.encode(lastDelivered))
        try await saveState("drive.cursor", Data(cursor!.utf8))
    }

    public func send(_ entities: [SyncEntity], serverFields: [String: Data]) async throws {
        let token = epoch
        let merged = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) }).merging(needsMerge) { local, _ in local }
        for entity in merged.values.sorted(by: { $0.id < $1.id }) {
            try check(token)
            if entity.kind == .chat && !enabledAI { continue }
            let headRevisions = heads(for: entity.id)
            let parents = headRevisions.map(\.logicalID).sorted()
            let ancestor = serverFields[entity.id].flatMap { try? JSONDecoder().decode(ServerFields.self, from: $0).entity }
            if needsMerge[entity.id] == nil,
               let existing = headRevisions.first(where: { $0.entity == entity }) {
                try await onEvent?(.acknowledged(entity, serverFields: try fields(entity, heads: [existing.logicalID])))
                continue
            }
            let logicalID = SyncCoding.hash(try SyncCoding.encode(entity) + Data(parents.joined(separator: ",").utf8))
            if let existing = index[entity.id]?.first(where: { $0.logicalID == logicalID }) {
                try await onEvent?(.acknowledged(entity, serverFields: try fields(entity, heads: [existing.logicalID])))
                needsMerge[entity.id] = nil
                continue
            }
            var stored = entity
            var payload: BlobManifest?
            if entity.body.count > 256 * 1024 {
                let source = staging.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try entity.body.write(to: source, options: .atomic)
                defer { try? FileManager.default.removeItem(at: source) }
                let manifest = try BlobManifest.describe(source)
                let directory = staging.appendingPathComponent("Chunks", isDirectory: true)
                try manifest.stage(source, directory: directory)
                for (chunkIndex, hash) in manifest.chunks.enumerated() {
                    try check(token)
                    try await uploadChunk(hash: hash, file: directory.appendingPathComponent(hash),
                        scope: "payload:\(entity.id)", bookID: entity.bookID,
                        blobHash: manifest.assetKey, index: chunkIndex)
                }
                stored.body = Data()
                payload = manifest
            }
            let envelope = Envelope(logicalID: logicalID, entity: stored, parents: parents,
                                    ancestor: nil, payload: payload)
            let body = try SyncCoding.encode(envelope)
            let name = entity.kind == .position
                ? "kodi-v1-position-" + SyncCoding.hash(Data("\(entity.id):\(entity.deviceID)".utf8))
                : "kodi-v1-entity-\(logicalID)"
            let existing = try await listFiles(query: "name = '\(name)'").first
            let file: FileInfo
            if let existing, entity.kind == .position {
                file = try await updateFile(existing.id, name: name, type: "position", data: body)
            } else if let existing { file = existing }
            else { file = try await createFile(name: name,
                type: entity.kind == .chat ? "chat" : (entity.kind == .position ? "position" : "entity"), data: body) }
            try check(token)
            let revision = Revision(fileID: file.id, logicalID: logicalID, entity: entity, parents: parents, ancestor: ancestor)
            if entity.kind == .position { index[entity.id]?.removeAll { $0.fileID == file.id } }
            index[entity.id, default: []].append(revision)
            needsMerge[entity.id] = nil
            try await saveState("drive.index", try SyncCoding.encode(index))
            try await onEvent?(.acknowledged(entity, serverFields: try fields(entity, heads: [logicalID])))
        }
    }

    public func uploadChunk(hash: String, file: URL, scope: String, bookID: String,
                            blobHash: String, index: Int) async throws {
        let contents = try Data(contentsOf: file)
        guard contents.count <= BlobManifest.chunkSize, SyncCoding.hash(contents) == hash else {
            throw SyncFailure.corruptAsset
        }
        let key = assetName(scope: scope, blobHash: blobHash, hash: hash)
        if assetFiles[key] != nil { return }
        if let existing = try await listFiles(query: "name = '\(key)'").first {
            assetFiles[key] = existing.id; return
        }
        let created = try await createFile(name: key, type: "asset", source: file,
            properties: ["scopeHash": SyncCoding.hash(Data(scope.utf8)), "blobHash": blobHash,
                         "contentHash": hash])
        assetFiles[key] = created.id
    }

    public func downloadChunk(hash: String, to file: URL, scope: String, blobHash: String) async throws {
        let key = assetName(scope: scope, blobHash: blobHash, hash: hash)
        let id: String
        if let cached = assetFiles[key] { id = cached }
        else if let found = try await listFiles(query: "name = '\(key)'").first {
            id = found.id; assetFiles[key] = id
        } else { throw SyncFailure.corruptAsset }
        let source = try await downloadFile(id)
        defer { try? FileManager.default.removeItem(at: source) }
        let data = try Data(contentsOf: source)
        guard data.count <= BlobManifest.chunkSize, SyncCoding.hash(data) == hash else { throw SyncFailure.corruptAsset }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    public func collectDeletedAssets(_ tombstones: [SyncEntity]) async throws {
        // An offline device can still publish a concurrent edit to a tombstoned
        // drawing. Its recovered copy needs the immutable chunks. Pruning requires
        // an all-device acknowledgement protocol; keep chunks until then.
        _ = tombstones
    }

    public func stop() async {
        epoch += 1
        needsMerge.removeAll(); index.removeAll(); assetFiles.removeAll()
        cursor = nil; markerID = nil; lastDelivered.removeAll(); initialized = false
    }

    private func heads(for id: String) -> [Revision] {
        let revisions = index[id] ?? []
        let parents = Set(revisions.flatMap(\.parents))
        return revisions.filter { !parents.contains($0.logicalID) }
    }

    private func deliverHeads(token: Int) async throws {
        for id in index.keys.sorted() {
            try check(token)
            let branches = heads(for: id).sorted { $0.logicalID < $1.logicalID }
            guard !branches.isEmpty else { continue }
            let ids = branches.map(\.logicalID)
            if lastDelivered[id] == ids { continue }
            var resolved = [branches[0].entity]
            for (offset, branch) in branches.dropFirst().enumerated() {
                let main = resolved.removeFirst()
                let ancestor = commonAncestor(Array(branches.prefix(offset + 1)) + [branch])
                let merge = try SyncMerge.resolve(local: main, remote: branch.entity, ancestor: ancestor)
                resolved.insert(contentsOf: merge, at: 0)
            }
            let main = resolved[0]
            if branches.count > 1 && main.kind != .position {
                for entity in resolved { needsMerge[entity.id] = entity }
            }
            for entity in resolved {
                guard entity.kind != .chat || enabledAI else { continue }
                try await onEvent?(.received(entity, serverFields: try fields(entity, heads: entity.id == id ? ids : [])))
            }
            lastDelivered[id] = ids
        }
    }

    private func commonAncestor(_ revisions: [Revision]) -> SyncEntity? {
        guard let first = revisions.first else { return nil }
        let known = Dictionary(uniqueKeysWithValues: (index[first.entity.id] ?? []).map { ($0.logicalID, $0) })
        func ancestry(_ revision: Revision) -> Set<String> {
            var seen = Set<String>(), stack = [revision.logicalID]
            while let id = stack.popLast() {
                if seen.insert(id).inserted { stack += known[id]?.parents ?? [] }
            }
            return seen
        }
        let shared = revisions.dropFirst().reduce(ancestry(first)) { $0.intersection(ancestry($1)) }
        // Choose a causally maximal common revision. Wall clocks can disagree
        // between Macs, so modifiedAt must not decide ancestry.
        let maximal = shared.filter { candidate in
            !shared.contains { other in other != candidate &&
                known[other].map { ancestry($0).contains(candidate) } == true }
        }
        return maximal.sorted().first.flatMap { known[$0]?.entity }
    }

    private func ingest(_ file: FileInfo, token: Int) async throws {
        guard let name = file.name else { return }
        if name == "kodi-v1-marker" { markerID = file.id; return }
        if name.hasPrefix("kodi-v1-asset-") { assetFiles[name] = file.id; return }
        guard name.hasPrefix("kodi-v1-entity-") || name.hasPrefix("kodi-v1-position-") else { return }
        if file.appProperties?["kodiType"] == "chat" && !enabledAI { return }
        let source = try await downloadFile(file.id)
        defer { try? FileManager.default.removeItem(at: source) }
        try check(token)
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: source))
        var entity = envelope.entity
        if let payload = envelope.payload {
            let directory = staging.appendingPathComponent("Chunks", isDirectory: true)
            let reconstructed = staging.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: reconstructed) }
            for hash in payload.chunks {
                try check(token)
                let chunk = directory.appendingPathComponent(hash)
                if let cached = try? Data(contentsOf: chunk),
                   cached.count > BlobManifest.chunkSize || SyncCoding.hash(cached) != hash {
                    try? FileManager.default.removeItem(at: chunk)
                }
                if !FileManager.default.fileExists(atPath: chunk.path) {
                    try await downloadChunk(hash: hash, to: chunk,
                        scope: "payload:\(entity.id)", blobHash: payload.assetKey)
                }
            }
            try payload.assemble(directory: directory, destination: reconstructed)
            entity.body = try Data(contentsOf: reconstructed)
        }
        let expectedID = SyncCoding.hash(try SyncCoding.encode(entity)
            + Data(envelope.parents.sorted().joined(separator: ",").utf8))
        guard envelope.schema == 1, envelope.logicalID == expectedID,
              (name == "kodi-v1-entity-\(envelope.logicalID)" ||
               (name.hasPrefix("kodi-v1-position-") && entity.kind == .position)) else {
            throw SyncFailure.unsupportedSchema
        }
        let revision = Revision(fileID: file.id, logicalID: envelope.logicalID,
                                entity: entity, parents: envelope.parents, ancestor: envelope.ancestor)
        if index[entity.id]?.contains(where: { $0.logicalID == envelope.logicalID && $0.fileID != file.id }) == true { return }
        index[entity.id]?.removeAll { $0.fileID == file.id }
        index[entity.id, default: []].append(revision)
    }

    private func fields(_ entity: SyncEntity, heads: [String]) throws -> Data {
        try SyncCoding.encode(ServerFields(entity: entity, heads: heads))
    }

    private func saveState(_ name: String, _ data: Data) async throws {
        try await onEvent?(.state(zone: name, data: data))
    }

    private func assetName(scope: String, blobHash: String, hash: String) -> String {
        "kodi-v1-asset-" + SyncCoding.hash(Data("\(scope):\(blobHash):\(hash)".utf8))
    }

    private func listFiles(query: String) async throws -> [FileInfo] {
        var result: [FileInfo] = [], page: String?
        repeat {
            let url = "https://www.googleapis.com/drive/v3/files?spaces=appDataFolder&pageSize=1000&fields=nextPageToken,files(id,name,appProperties,trashed)&q=\(encoded("(\(query)) and trashed = false"))" + (page.map { "&pageToken=\(encoded($0))" } ?? "")
            let batch: FileList = try await getJSON(url)
            result += batch.files
            page = batch.nextPageToken
        } while page != nil
        return result
    }

    private func fileInfo(_ id: String) async throws -> FileInfo {
        try await getJSON("https://www.googleapis.com/drive/v3/files/\(encoded(id))?fields=id,name,appProperties,trashed")
    }

    private func createFile(name: String, type: String, data: Data) async throws -> FileInfo {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let source = staging.appendingPathComponent(UUID().uuidString)
        try data.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        return try await createFile(name: name, type: type, source: source)
    }

    private func createFile(name: String, type: String, source: URL,
                            properties: [String: String] = [:]) async throws -> FileInfo {
        try await uploadFile(name: name, type: type, source: source, fileID: nil, properties: properties)
    }

    private func updateFile(_ id: String, name: String, type: String, data: Data) async throws -> FileInfo {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let source = staging.appendingPathComponent(UUID().uuidString)
        try data.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        return try await uploadFile(name: name, type: type, source: source, fileID: id)
    }

    private func uploadFile(name: String, type: String, source: URL, fileID: String?,
                            properties: [String: String] = [:]) async throws -> FileInfo {
        var appProperties = properties
        appProperties["kodiType"] = type
        var metadata: [String: Any] = ["name": name, "mimeType": "application/octet-stream",
                                       "appProperties": appProperties]
        if fileID == nil { metadata["parents"] = ["appDataFolder"] }
        let body = try JSONSerialization.data(withJSONObject: metadata)
        let endpoint = fileID.map { "https://www.googleapis.com/upload/drive/v3/files/\(encoded($0))" }
            ?? "https://www.googleapis.com/upload/drive/v3/files"
        var request = try await authorized(endpoint + "?uploadType=resumable&fields=id,name,appProperties",
                                           method: fileID == nil ? "POST" : "PATCH")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        request.setValue(String(size?.int64Value ?? 0), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = body
        let (startData, startResponse) = try await session.data(for: request)
        try validate(startResponse, body: startData)
        guard let location = (startResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location), url.scheme == "https", url.host == "www.googleapis.com" else {
            throw SyncFailure.unsupportedSchema
        }
        let length = size?.int64Value ?? 0
        var offset: Int64 = 0
        for _ in 0..<4 {
            var upload = URLRequest(url: url)
            upload.httpMethod = "PUT"
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let result: Data
            let response: URLResponse
            do {
                if offset == 0 {
                    (result, response) = try await session.upload(for: upload, fromFile: source)
                } else {
                    let handle = try FileHandle(forReadingFrom: source)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(offset))
                    upload.httpBody = try handle.readToEnd() ?? Data()
                    upload.setValue("bytes \(offset)-\(length - 1)/\(length)", forHTTPHeaderField: "Content-Range")
                    (result, response) = try await session.data(for: upload)
                }
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return try JSONDecoder().decode(FileInfo.self, from: result)
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 500,
                   let delay = retryDelay(http.value(forHTTPHeaderField: "Retry-After")) {
                    throw DriveAPIError(status: http.statusCode, reason: "backendError", retryAfter: delay)
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 308 && http.statusCode < 500 {
                    try validate(response, body: result)
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as DriveAPIError { throw error }
            catch { try Task.checkCancellation() }
            var probe = URLRequest(url: url)
            probe.httpMethod = "PUT"
            probe.setValue("bytes */\(length)", forHTTPHeaderField: "Content-Range")
            probe.setValue("0", forHTTPHeaderField: "Content-Length")
            let (statusBody, statusResponse) = try await session.data(for: probe)
            if let http = statusResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return try JSONDecoder().decode(FileInfo.self, from: statusBody)
            }
            guard let http = statusResponse as? HTTPURLResponse, http.statusCode == 308 else {
                try validate(statusResponse, body: statusBody)
                throw SyncFailure.unavailable
            }
            let range = http.value(forHTTPHeaderField: "Range")
            offset = range.flatMap { $0.split(separator: "-").last }.flatMap { Int64($0) }.map { $0 + 1 } ?? 0
            guard offset < length else { throw SyncFailure.corruptAsset }
        }
        throw SyncFailure.unavailable
    }

    private func downloadFile(_ id: String) async throws -> URL {
        let request = try await authorized("https://www.googleapis.com/drive/v3/files/\(encoded(id))?alt=media")
        let (file, response) = try await session.download(for: request)
        try validate(response, body: Data())
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    private func getJSON<T: Decodable>(_ url: String) async throws -> T {
        let request = try await authorized(url)
        let (data, response) = try await session.data(for: request)
        try validate(response, body: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func authorized(_ string: String, method: String = "GET") async throws -> URLRequest {
        guard let url = URL(string: string) else { throw SyncFailure.unsupportedSchema }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await credentials.accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncFailure.unavailable }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let details = (error?["errors"] as? [[String: Any]])?.first
            let reason = details?["reason"] as? String ?? (error?["status"] as? String ?? "unknown")
            let retry = retryDelay(http.value(forHTTPHeaderField: "Retry-After"))
            throw DriveAPIError(status: http.statusCode, reason: reason, retryAfter: retry)
        }
    }

    private func retryDelay(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == epoch else { throw CancellationError() }
    }

    private func encoded(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))) ?? string
    }
}
