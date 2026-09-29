import CryptoKit
import Foundation

public struct BlobManifest: Codable, Equatable, Sendable {
    public static let chunkSize = 16 * 1024 * 1024
    public var hash: String
    public var size: Int64
    public var chunks: [String]
    // An explicit re-import after deletion uses fresh asset roots, so delayed cleanup
    // from the old deletion cannot remove the replacement's chunks.
    public var generation: String?
    var assetKey: String { hash + (generation.map { ":" + $0 } ?? "") }
    func hasSameContent(as other: BlobManifest) -> Bool {
        hash == other.hash && size == other.size && chunks == other.chunks
    }

    public static func describe(_ file: URL) throws -> BlobManifest {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256(), chunks: [String] = [], size: Int64 = 0
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data); size += Int64(data.count); chunks.append(SyncCoding.hash(data))
        }
        return BlobManifest(hash: hasher.finalize().map { String(format: "%02x", $0) }.joined(), size: size, chunks: chunks)
    }

    public static func bookIdentity(file: URL, kind: DocumentKind) throws -> String {
        "\(kind.rawValue)-sha256:\(try describe(file).hash)"
    }

    /// Populate a checksum-addressed staging cache. Never stage the entire book in memory.
    func stage(_ source: URL, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        for hash in chunks {
            guard let data = try handle.read(upToCount: Self.chunkSize), SyncCoding.hash(data) == hash else {
                throw SyncFailure.corruptAsset
            }
            let target = directory.appendingPathComponent(hash)
            if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
        }
    }

    func assemble(directory: URL, destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            for hash in chunks {
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw SyncFailure.corruptAsset }
                let data = try Data(contentsOf: directory.appendingPathComponent(hash))
                guard data.count <= Self.chunkSize, SyncCoding.hash(data) == hash else { throw SyncFailure.corruptAsset }
                try handle.write(contentsOf: data)
            }
            try handle.close()
            guard try Self.describe(temporary).hasSameContent(as: self) else { throw SyncFailure.corruptAsset }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch { try? handle.close(); throw error }
    }
}
