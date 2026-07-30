import CryptoKit
import Foundation

/// An opened EPUB: the archive plus its parsed package and navigation.
public final class EPUBBook: @unchecked Sendable {
    public let container: EPUBContainer
    public let publication: Publication

    /// Stable key for persisted reading positions and annotations.
    ///
    /// Prefers the publication's own identifier, since that survives the file
    /// being moved or re-downloaded, and falls back to a digest of the file's
    /// name and size when a book omits one.
    public let bookID: String

    public var fileURL: URL { container.fileURL }
    public var title: String { publication.metadata.title }
    public var author: String { publication.metadata.authorText }

    public convenience init(fileURL: URL) throws {
        try self.init(container: EPUBContainer(fileURL: fileURL))
    }

    public init(container: EPUBContainer) throws {
        self.container = container

        let packagePath = try PackageParser.packagePath(in: container)
        let package = try PackageParser.parsePackage(at: packagePath, in: container)
        let toc = NavigationParser.parseTOC(
            package: package,
            packagePath: packagePath,
            container: container
        )

        publication = Publication(
            metadata: package.metadata,
            manifest: package.manifest,
            spine: package.spine,
            toc: toc,
            pageProgression: package.pageProgression,
            packagePath: packagePath
        )

        bookID = EPUBBook.makeBookID(
            identifier: package.metadata.identifier,
            fileURL: container.fileURL
        )
    }

    public func data(at path: String) throws -> Data {
        try container.data(at: path)
    }

    public var coverImageData: Data? {
        guard let path = publication.coverPath else { return nil }
        return try? container.data(at: path)
    }

    /// Chapter title for a position in the reading order, matched by walking
    /// backwards to the nearest table of contents entry.
    public func chapterTitle(forSpineIndex index: Int) -> String? {
        let order = publication.readingOrder
        guard order.indices.contains(index) else { return nil }

        let flattened = publication.toc.flatMap(\.flattened)
        if let exact = flattened.first(where: { $0.path == order[index].path }) {
            return exact.title
        }

        for candidate in stride(from: index - 1, through: 0, by: -1) {
            if let match = flattened.first(where: { $0.path == order[candidate].path }) {
                return match.title
            }
        }
        return nil
    }

    private static func makeBookID(identifier: String?, fileURL: URL) -> String {
        if let identifier, !identifier.isEmpty {
            return identifier
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let seed = "\(fileURL.lastPathComponent):\(size)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
