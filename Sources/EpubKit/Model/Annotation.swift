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
    /// True when a drawing sidecar exists for this highlight.
    public var hasDrawing: Bool

    public init(
        id: UUID = UUID(),
        locator: Locator,
        text: String,
        note: String? = nil,
        color: HighlightColor = .yellow,
        chapterTitle: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        anchorStatus: AnchorStatus = .unknown,
        hasDrawing: Bool = false
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
        self.hasDrawing = hasDrawing
    }

    public var hasNote: Bool {
        !(note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Markdown, a drawing, or both.
    public var hasContent: Bool { hasNote || hasDrawing }

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
        payload["hasNote"] = hasContent
        if hasNote { payload["note"] = note }
        return payload
    }

    private enum CodingKeys: String, CodingKey {
        case id, locator, text, note, color, chapterTitle, createdAt, modifiedAt, anchorStatus, hasDrawing
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
        hasDrawing = try container.decodeIfPresent(Bool.self, forKey: .hasDrawing) ?? false
    }
}

/// Markdown helpers shared by the editor, inspector, and export.
public enum NoteMarkdown {
    /// One chunk of a note when rendering Edit → Preview.
    public enum PreviewSegment: Equatable, Sendable {
        case prose(String)
        case code(String)
    }

    public enum TableAlignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    /// Structural blocks for the SwiftUI note preview renderer.
    public enum PreviewBlock: Equatable, Sendable {
        case paragraph(String)
        case unorderedList([String])
        case orderedList([String])
        case code(String)
        case table(header: [String], rows: [[String]], alignments: [TableAlignment])
    }

    /// Fence split, then prose → paragraphs / lists for reliable Preview rendering.
    public static func previewBlocks(of markdown: String) -> [PreviewBlock] {
        var blocks: [PreviewBlock] = []
        for segment in previewSegments(of: markdown) {
            switch segment {
            case let .code(code):
                blocks.append(.code(code))
            case let .prose(prose):
                blocks.append(contentsOf: proseBlocks(from: prose))
            }
        }
        return blocks
    }

    /// Line-scans prose into paragraphs, lists, and GFM tables.
    public static func proseBlocks(from prose: String) -> [PreviewBlock] {
        let lines = prose.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [PreviewBlock] = []
        var paragraphLines: [String] = []
        var unorderedItems: [String] = []
        var orderedItems: [String] = []

        func flushParagraph() {
            let text = paragraphLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushUnordered() {
            if !unorderedItems.isEmpty {
                blocks.append(.unorderedList(unorderedItems))
                unorderedItems.removeAll(keepingCapacity: true)
            }
        }

        func flushOrdered() {
            if !orderedItems.isEmpty {
                blocks.append(.orderedList(orderedItems))
                orderedItems.removeAll(keepingCapacity: true)
            }
        }

        func flushLists() {
            flushUnordered()
            flushOrdered()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                flushLists()
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let header = tableRowCells(line),
               let alignments = tableAlignments(lines[index + 1], columnCount: header.count)
            {
                flushParagraph()
                flushLists()
                var rows: [[String]] = []
                index += 2
                while index < lines.count,
                      let cells = tableRowCells(lines[index]),
                      tableAlignments(lines[index], columnCount: header.count) == nil
                {
                    rows.append(paddedCells(cells, count: header.count))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows, alignments: alignments))
                continue
            }

            if let item = unorderedListItem(line) {
                flushParagraph()
                flushOrdered()
                unorderedItems.append(item)
                index += 1
                continue
            }

            if let item = orderedListItem(line) {
                flushParagraph()
                flushUnordered()
                orderedItems.append(item)
                index += 1
                continue
            }

            flushLists()
            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        flushLists()
        return blocks
    }

    private static func tableRowCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var body = trimmed
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        let cells = body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    private static func tableAlignments(_ line: String, columnCount: Int) -> [TableAlignment]? {
        guard columnCount > 0, let cells = tableRowCells(line), !cells.isEmpty else { return nil }
        var alignments: [TableAlignment] = []
        alignments.reserveCapacity(cells.count)
        for cell in cells {
            let compact = cell.replacingOccurrences(of: " ", with: "")
            guard compact.range(of: #"^:?-{1,}:?$"#, options: .regularExpression) != nil else {
                return nil
            }
            let left = compact.hasPrefix(":")
            let right = compact.hasSuffix(":")
            if left && right {
                alignments.append(.center)
            } else if right {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        if alignments.count < columnCount {
            alignments.append(contentsOf: repeatElement(.leading, count: columnCount - alignments.count))
        } else if alignments.count > columnCount {
            alignments = Array(alignments.prefix(columnCount))
        }
        return alignments
    }

    private static func paddedCells(_ cells: [String], count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    private static func unorderedListItem(_ line: String) -> String? {
        let pattern = #"^\s*([-*+])\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let bodyRange = Range(result.range(at: 2), in: line)
        else { return nil }
        return String(line[bodyRange])
    }

    private static func orderedListItem(_ line: String) -> String? {
        let pattern = #"^\s*(\d+)\.\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let bodyRange = Range(result.range(at: 2), in: line)
        else { return nil }
        return String(line[bodyRange])
    }

    /// Splits markdown into prose and fenced code blocks (` ``` ` … ` ``` `).
    public static func previewSegments(of markdown: String) -> [PreviewSegment] {
        var segments: [PreviewSegment] = []
        var remaining = Substring(markdown)
        let fence = "```"

        while !remaining.isEmpty {
            guard let open = remaining.range(of: fence) else {
                let prose = String(remaining)
                if !prose.isEmpty { segments.append(.prose(prose)) }
                break
            }

            let before = String(remaining[..<open.lowerBound])
            if !before.isEmpty { segments.append(.prose(before)) }

            var afterOpen = remaining[open.upperBound...]
            // Optional language tag on the opening fence line.
            if let lineEnd = afterOpen.firstIndex(of: "\n") {
                afterOpen = afterOpen[afterOpen.index(after: lineEnd)...]
            } else {
                // Unclosed fence with no body — drop the opener and stop.
                break
            }

            if let close = afterOpen.range(of: fence) {
                var body = String(afterOpen[..<close.lowerBound])
                if body.hasSuffix("\n") { body.removeLast() }
                segments.append(.code(body))
                remaining = afterOpen[close.upperBound...]
                if remaining.first == "\n" {
                    remaining.removeFirst()
                }
            } else {
                // Unclosed fence: treat the rest as code.
                segments.append(.code(String(afterOpen)))
                break
            }
        }

        return segments
    }

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

    /// Inserts a two-column table, placing the caret in the first body cell.
    public static func insertTable(
        _ source: String,
        selection: Range<String.Index>
    ) -> (text: String, selection: Range<String.Index>) {
        let snippet = "| Column | Column |\n| --- | --- |\n|  |  |"
        let caretOffset = "| Column | Column |\n| --- | --- |\n| ".count
        var result = source
        result.replaceSubrange(selection, with: snippet)
        let caret = result.index(selection.lowerBound, offsetBy: caretOffset)
        return (result, caret..<caret)
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
            .filter(\.hasContent)
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
            if annotation.hasNote {
                parts.append(annotation.note ?? "")
                parts.append("")
            }
            if annotation.hasDrawing {
                parts.append("_Visual note attached._")
                parts.append("")
            }
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
    /// Ask AI conversation for this book. Optional so older library files decode.
    public var chatMessages: [ChatMessage]?

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
        bookmarks: [Bookmark] = [],
        chatMessages: [ChatMessage]? = nil
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
        self.chatMessages = chatMessages
    }

    /// Non-optional view of the stored conversation.
    public var conversation: [ChatMessage] {
        chatMessages ?? []
    }

    public func annotations(inSpineIndex index: Int) -> [Annotation] {
        annotations.filter { $0.locator.spineIndex == index }
    }
}
