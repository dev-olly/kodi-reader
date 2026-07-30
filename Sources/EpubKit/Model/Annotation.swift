import Foundation

/// A highlighted range, optionally carrying a note.
public struct Annotation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var locator: Locator
    /// The highlighted text, kept so the annotation is still meaningful in a
    /// list and so a damaged anchor can be reported rather than silently lost.
    public var text: String
    public var note: String?
    public var color: HighlightColor
    public var chapterTitle: String?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        locator: Locator,
        text: String,
        note: String? = nil,
        color: HighlightColor = .yellow,
        chapterTitle: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.locator = locator
        self.text = text
        self.note = note
        self.color = color
        self.chapterTitle = chapterTitle
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var hasNote: Bool {
        !(note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Shape the reader runtime expects in `__reader.setHighlights`.
    public var javaScriptPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": id.uuidString,
            "color": color.cssValue,
            "style": color == .underline ? "underline" : "fill",
            "start": [
                "elementPath": locator.start.elementPath,
                "offset": locator.start.offset,
            ],
        ]
        if let end = locator.end {
            payload["end"] = ["elementPath": end.elementPath, "offset": end.offset]
        }
        if hasNote { payload["note"] = note }
        return payload
    }
}

/// A saved place in the book, separate from the automatically tracked position.
public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var locator: Locator
    public var chapterTitle: String?
    public var excerpt: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        locator: Locator,
        chapterTitle: String? = nil,
        excerpt: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.locator = locator
        self.chapterTitle = chapterTitle
        self.excerpt = excerpt
        self.createdAt = createdAt
    }
}

/// Everything remembered about one book between launches.
public struct BookRecord: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    /// Security-scoped bookmark, so a sandboxed app can reopen the file.
    public var fileBookmark: Data?
    public var lastKnownPath: String?
    public var lastOpenedAt: Date
    public var position: Locator?
    public var progress: Double
    public var annotations: [Annotation]
    public var bookmarks: [Bookmark]

    public init(
        id: String,
        title: String,
        author: String,
        fileBookmark: Data? = nil,
        lastKnownPath: String? = nil,
        lastOpenedAt: Date = Date(),
        position: Locator? = nil,
        progress: Double = 0,
        annotations: [Annotation] = [],
        bookmarks: [Bookmark] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.fileBookmark = fileBookmark
        self.lastKnownPath = lastKnownPath
        self.lastOpenedAt = lastOpenedAt
        self.position = position
        self.progress = progress
        self.annotations = annotations
        self.bookmarks = bookmarks
    }

    public func annotations(inSpineIndex index: Int) -> [Annotation] {
        annotations.filter { $0.locator.spineIndex == index }
    }
}
