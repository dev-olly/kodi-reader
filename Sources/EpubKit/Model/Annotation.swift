import Foundation

/// Whether a highlight's locator still points at the quoted text in the book.
public enum AnchorStatus: String, Codable, Sendable, Hashable {
    /// Locator resolved cleanly.
    case resolved
    /// Locator was broken; repaired by searching for the stored quote.
    case repaired
    /// Quote could not be found in the chapter; note is kept, highlight is not painted.
    case orphaned
    /// Not yet checked this session (or loaded from an older library file).
    case unknown
}

/// A highlighted range, optionally carrying a markdown note.
public struct Annotation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var locator: Locator
    /// The highlighted text — also the note's title. Immutable quote for repair.
    public var text: String
    /// Markdown body. Plain text from older builds remains valid markdown.
    public var note: String?
    public var color: HighlightColor
    public var chapterTitle: String?
    public var createdAt: Date
    public var modifiedAt: Date
    /// Last known anchor health; defaults to `.unknown` when decoding old JSON.
    public var anchorStatus: AnchorStatus

    public init(
        id: UUID = UUID(),
        locator: Locator,
        text: String,
        note: String? = nil,
        color: HighlightColor = .yellow,
        chapterTitle: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        anchorStatus: AnchorStatus = .unknown
    ) {
        self.id = id
        self.locator = locator
        self.text = text
        self.note = note
        self.color = color
        self.chapterTitle = chapterTitle
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.anchorStatus = anchorStatus
    }

    public var hasNote: Bool {
        !(note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isOrphaned: Bool { anchorStatus == .orphaned }

    /// Quote used as the note title in the UI.
    public var title: String { text }

    /// Note body with common markdown markers stripped, for list previews.
    public var plainNotePreview: String {
        NoteMarkdown.plainPreview(of: note ?? "")
    }

    /// Shape the reader runtime expects in `__reader.setHighlights`.
    public var javaScriptPayload: [String: Any] {
        var payload: [String: Any] = [
            "id": id.uuidString,
            "color": color.cssValue,
            "style": color == .underline ? "underline" : "fill",
            "text": text,
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

    private enum CodingKeys: String, CodingKey {
        case id, locator, text, note, color, chapterTitle, createdAt, modifiedAt, anchorStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        locator = try container.decode(Locator.self, forKey: .locator)
        text = try container.decode(String.self, forKey: .text)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        color = try container.decode(HighlightColor.self, forKey: .color)
        chapterTitle = try container.decodeIfPresent(String.self, forKey: .chapterTitle)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        // Older library files omit this field.
        anchorStatus = try container.decodeIfPresent(AnchorStatus.self, forKey: .anchorStatus) ?? .unknown
    }
}

/// Markdown helpers shared by the editor, inspector, and export.
public enum NoteMarkdown {
    /// Strips a small set of markdown markers for list previews.
    public static func plainPreview(of markdown: String) -> String {
        var text = markdown
        let patterns = [
            #"\*\*(.+?)\*\*"#,
            #"__(.+?)__"#,
            #"\*(.+?)\*"#,
            #"_(.+?)_"#,
            #"\[(.+?)\]\(.+?\)"#,
            #"^#{1,6}\s+"#,
            #"^[-*+]\s+"#,
            #"^\d+\.\s+"#,
            #"`([^`]+)`"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: "$1",
                options: [.regularExpression]
            )
        }
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wraps `selection` with `prefix`/`suffix`, or inserts markers around the caret.
    public static func wrap(
        _ source: String,
        selection: Range<String.Index>,
        prefix: String,
        suffix: String
    ) -> (text: String, selection: Range<String.Index>) {
        let selected = String(source[selection])
        let replacement = prefix + selected + suffix
        var result = source
        result.replaceSubrange(selection, with: replacement)
        let start = selection.lowerBound
        let end = result.index(start, offsetBy: replacement.count)
        if selected.isEmpty {
            // Place caret between the markers.
            let caret = result.index(start, offsetBy: prefix.count)
            return (result, caret..<caret)
        }
        return (result, start..<end)
    }

    /// Wraps the selection in a fenced code block, or inserts an empty fence at the caret.
    public static func fenceCodeBlock(
        _ source: String,
        selection: Range<String.Index>
    ) -> (text: String, selection: Range<String.Index>) {
        let selected = String(source[selection])
        let prefix = "```\n"
        let suffix = "\n```"
        let replacement = prefix + selected + suffix
        var result = source
        result.replaceSubrange(selection, with: replacement)
        let start = selection.lowerBound
        if selected.isEmpty {
            let caret = result.index(start, offsetBy: prefix.count)
            return (result, caret..<caret)
        }
        let end = result.index(start, offsetBy: replacement.count)
        return (result, start..<end)
    }

    /// Prefixes each line of the selection (or the current line) with `marker`.
    public static func prefixLines(
        _ source: String,
        selection: Range<String.Index>,
        marker: String
    ) -> (text: String, selection: Range<String.Index>) {
        let lineStart = source[..<selection.lowerBound].lastIndex(of: "\n").map {
            source.index(after: $0)
        } ?? source.startIndex
        let lineEnd = source[selection.upperBound...].firstIndex(of: "\n") ?? source.endIndex
        let block = String(source[lineStart..<lineEnd])
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        let numbered = marker.hasSuffix(". ")
        let rewritten = lines.enumerated().map { index, line -> String in
            let content = String(line)
            if numbered {
                if content.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                    return content
                }
                return "\(index + 1). " + content
            }
            if content.hasPrefix(marker) { return content }
            return marker + content
        }.joined(separator: "\n")

        var result = source
        result.replaceSubrange(lineStart..<lineEnd, with: rewritten)
        let end = result.index(lineStart, offsetBy: rewritten.count)
        return (result, lineStart..<end)
    }

    /// Builds a markdown export for every annotation that has a note body.
    ///
    /// Each entry includes the highlighted passage as a blockquote and a
    /// citation line (chapter, author, title), then the user's note.
    public static func exportDocument(
        bookTitle: String,
        author: String,
        annotations: [Annotation]
    ) -> String {
        let authorLine = author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unknown Author"
            : author
        var parts: [String] = ["# Notes — \(bookTitle)", authorLine, ""]
        let noted = annotations
            .filter(\.hasNote)
            .sorted {
                ($0.locator.spineIndex, $0.createdAt) < ($1.locator.spineIndex, $1.createdAt)
            }

        if noted.isEmpty {
            parts.append("_No notes yet._")
            parts.append("")
            return parts.joined(separator: "\n")
        }

        for annotation in noted {
            let chapter = annotation.chapterTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let chapterHeading = (chapter?.isEmpty == false) ? chapter! : "Untitled section"

            parts.append("### \(chapterHeading)")
            parts.append("")
            parts.append(blockquote(annotation.text))
            parts.append("")
            parts.append("*— \(chapterHeading), \(authorLine), \(bookTitle)*")
            parts.append("")
            parts.append(annotation.note ?? "")
            parts.append("")
            parts.append("---")
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }

    /// Prefixes each line with `> ` for a Markdown blockquote.
    public static func blockquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ">" }
        return trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let content = String(line)
                return content.isEmpty ? ">" : "> \(content)"
            }
            .joined(separator: "\n")
    }
}

/// Result of resolving one highlight in the current spine document.
public struct AnchorResolution: Sendable, Hashable {
    public var id: UUID
    public var status: AnchorStatus
    /// Present when the locator was repaired.
    public var locator: Locator?

    public init(id: UUID, status: AnchorStatus, locator: Locator? = nil) {
        self.id = id
        self.status = status
        self.locator = locator
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
    /// Security-scoped bookmark for the original user-selected file (best-effort).
    public var fileBookmark: Data?
    /// Original path the user opened from (display / Locate hint only).
    public var lastKnownPath: String?
    /// Copy inside Application Support, e.g. `Books/<id>.epub` — primary reopen source.
    public var importedRelativePath: String?
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
        importedRelativePath: String? = nil,
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
        self.importedRelativePath = importedRelativePath
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
