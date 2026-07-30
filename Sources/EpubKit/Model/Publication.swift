import Foundation

/// Left-to-right or right-to-left reading, declared by the spine.
public enum PageProgressionDirection: String, Sendable {
    case ltr
    case rtl
}

public struct Metadata: Sendable, Equatable {
    public var title: String
    public var creators: [String]
    public var language: String?
    public var identifier: String?
    public var publisher: String?
    public var bookDescription: String?
    /// Manifest id of the cover image, from either the EPUB 3 `cover-image`
    /// property or the EPUB 2 `<meta name="cover">` hint.
    public var coverItemID: String?

    public var authorText: String {
        creators.isEmpty ? "Unknown Author" : creators.joined(separator: ", ")
    }
}

public struct ManifestItem: Sendable, Equatable {
    public let id: String
    /// Path within the archive, already resolved against the package document.
    public let path: String
    public let mediaType: String
    public let properties: Set<String>

    public var isNavigationDocument: Bool { properties.contains("nav") }
    public var isCoverImage: Bool { properties.contains("cover-image") }
}

public struct SpineItem: Sendable, Equatable {
    public let idref: String
    /// Path within the archive.
    public let path: String
    public let mediaType: String
    public let isLinear: Bool
}

public struct TOCEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    /// Path within the archive, without the fragment.
    public let path: String
    /// Element id after `#`, when the entry points inside a document.
    public let fragment: String?
    public let children: [TOCEntry]

    public init(
        id: UUID = UUID(),
        title: String,
        path: String,
        fragment: String? = nil,
        children: [TOCEntry] = []
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.fragment = fragment
        self.children = children
    }

    /// Depth-first flattening, used to match a spine position back to a chapter.
    public var flattened: [TOCEntry] {
        [self] + children.flatMap(\.flattened)
    }
}

public struct Publication: Sendable {
    public let metadata: Metadata
    public let manifest: [String: ManifestItem]
    public let spine: [SpineItem]
    public let toc: [TOCEntry]
    public let pageProgression: PageProgressionDirection
    /// Path of the package document within the archive.
    public let packagePath: String

    public var coverPath: String? {
        if let id = metadata.coverItemID, let item = manifest[id] {
            return item.path
        }
        return manifest.values.first(where: \.isCoverImage)?.path
    }

    /// Spine entries that participate in the linear reading order.
    public var readingOrder: [SpineItem] {
        let linear = spine.filter(\.isLinear)
        return linear.isEmpty ? spine : linear
    }

    public func spineIndex(forPath path: String) -> Int? {
        readingOrder.firstIndex { $0.path == path }
    }
}
