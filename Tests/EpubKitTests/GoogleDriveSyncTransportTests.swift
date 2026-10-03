import Foundation
import XCTest
@testable import EpubKit

@MainActor
private final class DriveTestCredentials: GoogleDriveCredentialProvider {
    func accessToken() async throws -> String { "test-token" }
}

private final class DriveURLProtocol: URLProtocol {
    static var files: [String: (name: String, type: String, body: Data)] = [:]
    static var requestedMedia: [String] = []
    static var pendingUpload: (name: String, type: String)?
    static var pendingUpdateID: String?
    static var appearAfterListing: (id: String, name: String, type: String, body: Data)?
    static var changedFileID: String?
    static var failMediaOnce: String?
    static var interruptUploadOnce = false
    static var partialUpload = Data()
    static var expireCursorOnce = false
    static var removedFileID: String?
    static var startTokenRequests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func requestBody() -> Data {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return bytes
    }
    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let media = query.contains { $0.name == "alt" && $0.value == "media" }
        let id = path.split(separator: "/").last.map(String.init) ?? ""
        let status: Int
        let body: Data
        var rangeHeader: String?
        if ["POST", "PATCH"].contains(request.httpMethod ?? ""), path.hasPrefix("/upload/drive/v3/files") {
            let json = (try? JSONSerialization.jsonObject(with: requestBody())) as? [String: Any]
            let properties = json?["appProperties"] as? [String: String]
            Self.pendingUpload = (json?["name"] as? String ?? "missing", properties?["kodiType"] ?? "entity")
            Self.pendingUpdateID = request.httpMethod == "PATCH" ? id : nil
            status = 200; body = Data()
        } else if request.httpMethod == "PUT", path.hasPrefix("/upload/session/") {
            let contentRange = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            if contentRange.hasPrefix("bytes */") {
                status = 308; body = Data()
                if !Self.partialUpload.isEmpty { rangeHeader = "bytes=0-\(Self.partialUpload.count - 1)" }
            } else if Self.interruptUploadOnce {
                let bytes = requestBody()
                Self.partialUpload = Data(bytes.prefix(bytes.count / 2))
                Self.interruptUploadOnce = false
                status = 503; body = Data(#"{"error":{"errors":[{"reason":"backendError"}]}}"#.utf8)
            } else {
                let bytes = Self.partialUpload + requestBody()
                Self.partialUpload = Data()
                let newID = Self.pendingUpdateID ?? "uploaded-\(Self.files.count)"
                let pending = Self.pendingUpload ?? ("missing", "entity")
                Self.files[newID] = (pending.name, pending.type, bytes)
                status = 200
                body = (try? JSONSerialization.data(withJSONObject: ["id": newID, "name": pending.name,
                    "appProperties": ["kodiType": pending.type]])) ?? Data()
            }
        } else if path.hasSuffix("/changes/startPageToken") {
            Self.startTokenRequests += 1
            status = 200; body = Data(#"{"startPageToken":"1"}"#.utf8)
        } else if path.hasSuffix("/changes") {
            if Self.expireCursorOnce {
                Self.expireCursorOnce = false
                status = 410; body = Data(#"{"error":{"errors":[{"reason":"pageTokenExpired"}]}}"#.utf8)
            } else if let removed = Self.removedFileID {
                status = 200
                body = (try? JSONSerialization.data(withJSONObject: [
                    "changes": [["fileId": removed, "removed": true]], "newStartPageToken": "2"
                ])) ?? Data()
            } else if let changed = Self.changedFileID, let file = Self.files[changed] {
                status = 200
                body = (try? JSONSerialization.data(withJSONObject: [
                    "changes": [["fileId": changed, "file": ["id": changed, "name": file.name,
                        "appProperties": ["kodiType": file.type]]]], "newStartPageToken": "2"
                ])) ?? Data()
            } else { status = 200; body = Data(#"{"changes":[],"newStartPageToken":"2"}"#.utf8) }
        } else if path.hasSuffix("/about") {
            status = 200; body = Data(#"{"user":{"permissionId":"test-account","emailAddress":"reader@example.com"}}"#.utf8)
        } else if path.hasSuffix("/files") {
            let filter = query.first { $0.name == "q" }?.value ?? ""
            let files = Self.files.map { key, value in
                (key, value)
            }.filter { filter.contains("appDataFolder") || filter.contains($0.1.name) }
                .map { key, value -> [String: Any] in
                    ["id": key, "name": value.name, "appProperties": ["kodiType": value.type]]
                }
            status = 200
            body = (try? JSONSerialization.data(withJSONObject: ["files": files])) ?? Data()
            if filter.contains("appDataFolder"), let late = Self.appearAfterListing {
                Self.files[late.id] = (late.name, late.type, late.body)
                Self.changedFileID = late.id
                Self.appearAfterListing = nil
            }
        } else if media, Self.failMediaOnce == id {
            Self.failMediaOnce = nil
            status = 503; body = Data(#"{"error":{"errors":[{"reason":"backendError"}]}}"#.utf8)
        } else if media, let file = Self.files[id] {
            Self.requestedMedia.append(id)
            status = 200; body = file.body
        } else if let file = Self.files[id] {
            status = 200
            body = (try? JSONSerialization.data(withJSONObject: [
                "id": id, "name": file.name, "appProperties": ["kodiType": file.type], "trashed": false
            ])) ?? Data()
        } else {
            status = 404; body = Data(#"{"error":{"errors":[{"reason":"notFound"}]}}"#.utf8)
        }
        var headers = ["Content-Type": "application/json"]
        if ["POST", "PATCH"].contains(request.httpMethod ?? ""), path.hasPrefix("/upload/drive/v3/files") {
            headers["Location"] = "https://www.googleapis.com/upload/session/1"
        }
        if let rangeHeader { headers["Range"] = rangeHeader }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class GoogleDriveSyncTransportTests: XCTestCase {
    private struct Envelope: Codable {
        var schema = 1
        var logicalID: String
        var entity: SyncEntity
        var parents: [String]
        var ancestor: SyncEntity?
    }

    override func tearDown() {
        DriveURLProtocol.files = [:]
        DriveURLProtocol.requestedMedia = []
        DriveURLProtocol.pendingUpload = nil
        DriveURLProtocol.pendingUpdateID = nil
        DriveURLProtocol.appearAfterListing = nil
        DriveURLProtocol.changedFileID = nil
        DriveURLProtocol.failMediaOnce = nil
        DriveURLProtocol.interruptUploadOnce = false
        DriveURLProtocol.partialUpload = Data()
        DriveURLProtocol.expireCursorOnce = false
        DriveURLProtocol.removedFileID = nil
        DriveURLProtocol.startTokenRequests = 0
        super.tearDown()
    }

    private func transport() -> GoogleDriveSyncTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DriveURLProtocol.self]
        return GoogleDriveSyncTransport(credentials: DriveTestCredentials(),
            stagingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("kodi-drive-test-\(UUID().uuidString)"),
            session: URLSession(configuration: configuration))
    }

    @discardableResult
    private func add(_ entity: SyncEntity, parents: [String] = [], ancestor: SyncEntity? = nil) throws -> String {
        let logicalID = SyncCoding.hash(try SyncCoding.encode(entity) + Data(parents.sorted().joined(separator: ",").utf8))
        let fileID = "file-\(DriveURLProtocol.files.count)"
        DriveURLProtocol.files[fileID] = ("kodi-v1-entity-\(logicalID)",
            entity.kind == .chat ? "chat" : "entity",
            try SyncCoding.encode(Envelope(logicalID: logicalID, entity: entity, parents: parents, ancestor: ancestor)))
        return logicalID
    }

    private func note(_ text: String, modifiedAt: Date, device: String) throws -> SyncEntity {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var annotation = Annotation(locator: Locator(spineIndex: 0,
            start: TextPosition(elementPath: [0], offset: 0)), text: "quote", note: text)
        annotation.id = id
        return SyncEntity(bookID: "epub-sha256:" + String(repeating: "a", count: 64),
            kind: .annotation, key: id.uuidString,
            body: try SyncCoding.encode(SyncedAnnotation(annotation: annotation, drawing: nil)),
            modifiedAt: modifiedAt, deviceID: device)
    }

    func testInitialFetchReadsMetadataWithoutAssetsOrDisabledAI() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let entity = try note("remote note", modifiedAt: Date(timeIntervalSince1970: 1), device: "mac-a")
        try add(entity)
        DriveURLProtocol.files["asset"] = ("kodi-v1-asset-unused", "asset", Data(repeating: 1, count: 128))
        let chat = SyncEntity(bookID: entity.bookID, kind: .chat, key: UUID().uuidString,
                              body: Data("private".utf8), deviceID: "mac-a")
        try add(chat)
        let drive = transport()
        var received: [SyncEntity] = [], states: [String: Data] = [:]
        drive.onEvent = { event in
            if case .received(let entity, _) = event { received.append(entity) }
            if case .state(let key, let value) = event { states[key] = value }
        }
        let account = try await drive.accountID()
        XCTAssertEqual(account, "test-account")
        try await drive.configure(aiEnabled: false, states: states)
        try await drive.fetch()
        XCTAssertEqual(received, [entity])
        XCTAssertFalse(DriveURLProtocol.requestedMedia.contains("asset"))
        XCTAssertNotNil(states["drive.cursor"])
    }

    func testInitialScanReplaysChangesThatArriveAfterSnapshot() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let late = try note("arrived during scan", modifiedAt: Date(timeIntervalSince1970: 8), device: "mac-b")
        let logicalID = SyncCoding.hash(try SyncCoding.encode(late))
        DriveURLProtocol.appearAfterListing = ("late", "kodi-v1-entity-\(logicalID)", "entity",
            try SyncCoding.encode(Envelope(logicalID: logicalID, entity: late, parents: [], ancestor: nil)))
        let drive = transport()
        var received: [SyncEntity] = []
        drive.onEvent = { event in if case .received(let entity, _) = event { received.append(entity) } }
        try await drive.configure(aiEnabled: false, states: [:])
        try await drive.fetch()
        XCTAssertEqual(received, [late])
    }

    func testExpiredChangeCursorRescansWithoutLosingMetadata() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let entity = try note("still present", modifiedAt: Date(timeIntervalSince1970: 1), device: "mac-a")
        try add(entity)
        let drive = transport()
        var received: [SyncEntity] = []
        drive.onEvent = { event in if case .received(let value, _) = event { received.append(value) } }
        DriveURLProtocol.expireCursorOnce = true
        try await drive.configure(aiEnabled: false, states: [:])
        try await drive.fetch()
        XCTAssertEqual(received, [entity])
        XCTAssertEqual(DriveURLProtocol.startTokenRequests, 2)
    }

    func testRemovedKnownMetadataPausesInsteadOfResurrectingCloudData() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let entity = try note("deleted outside Kodi", modifiedAt: Date(timeIntervalSince1970: 1), device: "mac-a")
        try add(entity)
        let id = try XCTUnwrap(DriveURLProtocol.files.first { $0.value.type == "entity" }?.key)
        let drive = transport()
        var reset = false
        drive.onEvent = { event in if case .cloudReset = event { reset = true } }
        try await drive.configure(aiEnabled: false, states: [:])
        try await drive.fetch()
        DriveURLProtocol.removedFileID = id
        do { try await drive.fetch(); XCTFail("Expected a cloud reset pause") }
        catch SyncFailure.cloudReset { XCTAssertTrue(reset) }
    }

    func testConcurrentNoteHeadsPreserveRecoveredVersion() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let base = try note("base", modifiedAt: Date(timeIntervalSince1970: 1), device: "mac-a")
        let root = try add(base)
        let left = try note("left", modifiedAt: Date(timeIntervalSince1970: 2), device: "mac-a")
        let right = try note("right", modifiedAt: Date(timeIntervalSince1970: 3), device: "mac-b")
        try add(left, parents: [root], ancestor: base)
        try add(right, parents: [root], ancestor: base)
        let drive = transport()
        var received: [SyncEntity] = []
        drive.onEvent = { event in if case .received(let entity, _) = event { received.append(entity) } }
        try await drive.configure(aiEnabled: false, states: [:])
        try await drive.fetch()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(Set(received.map(\.id)).count, 2)
        XCTAssertTrue(received.contains { (try? $0.value(SyncedAnnotation.self).annotation.recoveredFrom) != nil })
        try await drive.send([], serverFields: [:])
        let anotherMac = transport()
        var replayed: [SyncEntity] = []
        anotherMac.onEvent = { event in if case .received(let entity, _) = event { replayed.append(entity) } }
        try await anotherMac.configure(aiEnabled: false, states: [:])
        try await anotherMac.fetch()
        XCTAssertEqual(Set(replayed.map(\.id)), Set(received.map(\.id)))
    }

    func testUploadedEntityCanBeReadBySecondMac() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let original = try note("from first Mac", modifiedAt: Date(timeIntervalSince1970: 2), device: "mac-a")
        let first = transport()
        first.onEvent = { _ in }
        try await first.configure(aiEnabled: false, states: [:])
        try await first.fetch()
        try await first.send([original], serverFields: [:])
        let second = transport()
        var received: [SyncEntity] = []
        second.onEvent = { event in if case .received(let entity, _) = event { received.append(entity) } }
        try await second.configure(aiEnabled: false, states: [:])
        try await second.fetch()
        XCTAssertEqual(received, [original])
    }

    func testChunkRoundTripAndCorruptionProtection() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        let data = Data(repeating: 0x41, count: 1024 * 1024)
        try data.write(to: source)
        let hash = SyncCoding.hash(data)
        let drive = transport()
        drive.onEvent = { _ in }
        try await drive.configure(aiEnabled: false, states: [:])
        try await drive.uploadChunk(hash: hash, file: source, scope: "scope", bookID: "book", blobHash: "blob", index: 0)
        try await drive.downloadChunk(hash: hash, to: destination, scope: "scope", blobHash: "blob")
        XCTAssertEqual(try Data(contentsOf: destination), data)
        let uploaded = try XCTUnwrap(DriveURLProtocol.files.first { $0.value.type == "asset" })
        DriveURLProtocol.files[uploaded.key] = (uploaded.value.name, "asset", Data("bad".utf8))
        let second = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: second) }
        do {
            try await drive.downloadChunk(hash: hash, to: second, scope: "scope", blobHash: "blob")
            XCTFail("A corrupt chunk must be rejected")
        } catch SyncFailure.corruptAsset {
            XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        }
    }

    func testLargeConversationUsesVerifiedPayloadChunks() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let chat = SyncEntity(bookID: "epub-sha256:" + String(repeating: "d", count: 64),
            kind: .chat, key: UUID().uuidString, body: Data(repeating: 0x42, count: 1024 * 1024),
            deviceID: "mac-a")
        let first = transport()
        first.onEvent = { _ in }
        try await first.configure(aiEnabled: true, states: [:])
        try await first.fetch()
        try await first.send([chat], serverFields: [:])
        XCTAssertEqual(DriveURLProtocol.files.values.filter { $0.type == "asset" }.count, 1)
        let metadata = try XCTUnwrap(DriveURLProtocol.files.values.first { $0.type == "chat" })
        XCTAssertLessThan(metadata.body.count, 10 * 1024)
        let second = transport()
        var received: [SyncEntity] = []
        second.onEvent = { event in if case .received(let entity, _) = event { received.append(entity) } }
        try await second.configure(aiEnabled: true, states: [:])
        try await second.fetch()
        XCTAssertEqual(received, [chat])
    }

    func testInterruptedLargeAssetResumesWithoutDuplicateChunks() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("large.pdf")
        let destination = root.appendingPathComponent("download.pdf")
        try Data(repeating: 0x41, count: BlobManifest.chunkSize + 257).write(to: source)
        let manifest = try BlobManifest.describe(source)
        let staged = root.appendingPathComponent("chunks")
        try manifest.stage(source, directory: staged)
        let drive = transport()
        drive.onEvent = { _ in }
        try await drive.configure(aiEnabled: false, states: [:])
        for (index, hash) in manifest.chunks.enumerated() {
            try await drive.uploadChunk(hash: hash, file: staged.appendingPathComponent(hash),
                scope: "book:large:metadata", bookID: "large", blobHash: manifest.assetKey, index: index)
        }
        let count = DriveURLProtocol.files.values.filter { $0.type == "asset" }.count
        XCTAssertEqual(count, 2)
        try await drive.uploadChunk(hash: manifest.chunks[0], file: staged.appendingPathComponent(manifest.chunks[0]),
            scope: "book:large:metadata", bookID: "large", blobHash: manifest.assetKey, index: 0)
        XCTAssertEqual(DriveURLProtocol.files.values.filter { $0.type == "asset" }.count, count)
        let asset = try XCTUnwrap(DriveURLProtocol.files.first {
            $0.value.type == "asset" && SyncCoding.hash($0.value.body) == manifest.chunks[0]
        })
        DriveURLProtocol.failMediaOnce = asset.key
        let downloaded = root.appendingPathComponent("downloaded")
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        do {
            try await drive.downloadChunk(hash: manifest.chunks[0],
                to: downloaded.appendingPathComponent(manifest.chunks[0]),
                scope: "book:large:metadata", blobHash: manifest.assetKey)
            XCTFail("Expected an interrupted download")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.appendingPathComponent(manifest.chunks[0]).path))
        }
        for hash in manifest.chunks {
            try await drive.downloadChunk(hash: hash, to: downloaded.appendingPathComponent(hash),
                scope: "book:large:metadata", blobHash: manifest.assetKey)
        }
        try manifest.assemble(directory: downloaded, destination: destination)
        XCTAssertEqual(try BlobManifest.describe(destination), manifest)
    }

    func testInterruptedResumableUploadContinuesFromServerRange() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        let bytes = Data(repeating: 0x7a, count: 1024 * 1024)
        try bytes.write(to: source)
        let drive = transport()
        drive.onEvent = { _ in }
        try await drive.configure(aiEnabled: false, states: [:])
        DriveURLProtocol.interruptUploadOnce = true
        try await drive.uploadChunk(hash: SyncCoding.hash(bytes), file: source,
            scope: "book:resumed:metadata", bookID: "resumed", blobHash: "blob", index: 0)
        let uploaded = try XCTUnwrap(DriveURLProtocol.files.values.first { $0.type == "asset" })
        XCTAssertEqual(uploaded.body, bytes)
    }

    func testReadingPositionUpdatesOneFilePerDevice() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let drive = transport()
        drive.onEvent = { _ in }
        try await drive.configure(aiEnabled: false, states: [:])
        try await drive.fetch()
        let bookID = "epub-sha256:" + String(repeating: "b", count: 64)
        let first = SyncEntity(bookID: bookID, kind: .position, key: "position",
            body: try SyncCoding.encode(SyncedPosition(locator: nil, progress: 0.1, lastOpenedAt: Date())),
            deviceID: "mac-a")
        var second = first
        second.body = try SyncCoding.encode(SyncedPosition(locator: nil, progress: 0.5, lastOpenedAt: Date()))
        second.modifiedAt = Date().addingTimeInterval(1)
        try await drive.send([first], serverFields: [:])
        try await drive.send([second], serverFields: [:])
        XCTAssertEqual(DriveURLProtocol.files.values.filter { $0.name.hasPrefix("kodi-v1-position-") }.count, 1)
        let otherMac = transport()
        var positions: [SyncEntity] = []
        otherMac.onEvent = { event in if case .received(let entity, _) = event { positions.append(entity) } }
        try await otherMac.configure(aiEnabled: false, states: [:])
        try await otherMac.fetch()
        XCTAssertEqual(positions, [second])
    }

    func testAIHistoryRescansWhenEnabledAfterBeingOff() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let bookID = "epub-sha256:" + String(repeating: "c", count: 64)
        let chat = SyncEntity(bookID: bookID, kind: .chat, key: UUID().uuidString,
                              body: Data("saved conversation".utf8), deviceID: "mac-a")
        try add(chat)
        let drive = transport()
        var states: [String: Data] = [:], received: [SyncEntity] = []
        drive.onEvent = { event in
            if case .state(let key, let data) = event { states[key] = data }
            if case .received(let entity, _) = event { received.append(entity) }
        }
        try await drive.configure(aiEnabled: false, states: states)
        try await drive.fetch()
        XCTAssertTrue(received.isEmpty)
        await drive.stop()
        try await drive.configure(aiEnabled: true, states: states)
        try await drive.fetch()
        XCTAssertEqual(received, [chat])
    }

    func testRestartWithAIAlreadyEnabledReusesSavedCursor() async throws {
        DriveURLProtocol.files["marker"] = ("kodi-v1-marker", "marker", Data("1".utf8))
        let chat = SyncEntity(bookID: "epub-sha256:" + String(repeating: "e", count: 64),
            kind: .chat, key: UUID().uuidString, body: Data("saved conversation".utf8), deviceID: "mac-a")
        try add(chat)
        var states: [String: Data] = [:]
        let first = transport()
        first.onEvent = { event in if case .state(let name, let data) = event { states[name] = data } }
        try await first.configure(aiEnabled: true, states: states)
        try await first.fetch()
        XCTAssertEqual(DriveURLProtocol.startTokenRequests, 1)
        let restarted = transport()
        restarted.onEvent = { _ in }
        try await restarted.configure(aiEnabled: true, states: states)
        try await restarted.fetch()
        XCTAssertEqual(DriveURLProtocol.startTokenRequests, 1)
    }
}
