import CryptoKit
import Foundation
import Observation

public enum SyncProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, iCloud, googleDrive
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: "Off"
        case .iCloud: "iCloud"
        case .googleDrive: "Google Drive"
        }
    }
}

public enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, notesOnly, booksAndNotes
    public var id: String { rawValue }
    public var title: String {
        switch self { case .off: "Off"; case .notesOnly: "Notes only"; case .booksAndNotes: "Books and notes" }
    }
}

public struct SyncPreferences: Codable, Equatable, Sendable {
    public var mode: SyncMode = .off
    public var syncAIHistory = false
    public init(mode: SyncMode = .off, syncAIHistory: Bool = false) {
        self.mode = mode; self.syncAIHistory = syncAIHistory
    }
}

@MainActor @Observable
public final class SyncStatus {
    public enum Phase: String, Sendable {
        case off = "Off", synced = "Synced", syncing = "Syncing", offline = "Offline"
        case unavailable = "Cloud unavailable", storageFull = "Storage full", error = "Sync needs attention"
    }
    public internal(set) var phase: Phase = .off
    public internal(set) var message: String?
    public internal(set) var lastSuccessfulSync: Date?
    public internal(set) var downloads: [String: Double] = [:]
    public internal(set) var requiresAcknowledgement = false
    public init() {}
}

public enum SyncEntityKind: String, Codable, Sendable { case book, annotation, bookmark, position, chat }

/// Only portable data is encoded here. The local BookRecord is never uploaded.
public struct SyncEntity: Codable, Equatable, Sendable {
    public var id: String
    public var bookID: String
    public var kind: SyncEntityKind
    public var body: Data
    public var modifiedAt: Date
    public var deviceID: String
    public var deleted: Bool = false
    public init(bookID: String, kind: SyncEntityKind, key: String, body: Data,
                modifiedAt: Date = Date(), deviceID: String, deleted: Bool = false) {
        id = "\(kind.rawValue):\(bookID):\(key)"
        self.bookID = bookID; self.kind = kind; self.body = body
        self.modifiedAt = modifiedAt; self.deviceID = deviceID; self.deleted = deleted
    }
    public func value<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: body) }
}

struct SyncedBook: Codable, Equatable {
    var title: String
    var author: String
    var kind: DocumentKind
    var sourceURL: URL?
    var file: BlobManifest?
}

struct SyncedAnnotation: Codable, Equatable {
    var annotation: Annotation
    var drawing: BlobManifest?
}

struct SyncedPosition: Codable, Equatable {
    var locator: Locator?
    var progress: Double
    var lastOpenedAt: Date
}

struct SyncJournal: Codable {
    var version = 1
    var deviceID = UUID().uuidString
    var accountID: String?
    var preferences = SyncPreferences()
    var local: [String: SyncEntity] = [:]
    var base: [String: SyncEntity] = [:]
    var pending: [String: SyncEntity] = [:]
    var serverFields: [String: Data] = [:]
    var engineStates: [String: Data] = [:]
    var deferred: [SyncEntity] = []
    var lastSuccessfulSync: Date?
    var lastPositionSend: Date?
    // Recovery libraries remain local after a concurrent whole-book deletion.
    var detachedBooks: Set<String>?
    var collectedTombstones: Set<String>?
    var assetGenerations: [String: String]?
    var pendingRestorations: [String: String]?
    var requiresAcknowledgement = false
}

enum SyncCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func uuid(_ seed: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public enum SyncFailure: LocalizedError {
    case unavailable, accountChanged, cloudReset, corruptAsset, missingFile, categoryDisabled, unsupportedSchema
    case googleSignInRequired, googleNotConfigured, googleQuotaExceeded, googleRateLimited
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Cloud sync is unavailable. Your local library is safe."
        case .accountChanged: "Your cloud account changed. Enable sync again to copy this Mac’s local library to the current account."
        case .cloudReset: "Kodi’s cloud data was removed. Enable sync again to copy this Mac’s local library."
        case .corruptAsset: "The download could not be verified. Your existing local copy was kept. Try again."
        case .missingFile: "Locate this book’s file to enable sync."
        case .categoryDisabled: "Enable Books and notes to download this book."
        case .unsupportedSchema: "This cloud data needs a newer version of Kodi Reader."
        case .googleSignInRequired: "Connect Google Drive again to resume sync. Your local changes are safe."
        case .googleNotConfigured: "Google Drive sync is not configured in this build."
        case .googleQuotaExceeded: "Google Drive storage is full. Local changes will sync when space is available."
        case .googleRateLimited: "Google Drive is busy. Kodi will retry later."
        }
    }
}

@MainActor
public protocol SyncTransport: AnyObject {
    var onEvent: ((SyncTransportEvent) async throws -> Void)? { get set }
    func accountID() async throws -> String
    func configure(aiEnabled: Bool, states: [String: Data]) async throws
    func fetch() async throws
    func send(_ entities: [SyncEntity], serverFields: [String: Data]) async throws
    func uploadChunk(hash: String, file: URL, scope: String, bookID: String, blobHash: String, index: Int) async throws
    func downloadChunk(hash: String, to file: URL, scope: String, blobHash: String) async throws
    func collectDeletedAssets(_ tombstones: [SyncEntity]) async throws
    func stop() async
}

public enum SyncTransportEvent {
    case received(SyncEntity, serverFields: Data)
    case acknowledged(SyncEntity, serverFields: Data)
    case state(zone: String, data: Data)
    case accountChanged
    case cloudReset
    case failed(Error)
}
