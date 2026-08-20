import Foundation

/// Who wrote a turn in the Ask AI conversation.
public enum ChatRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
}

/// A quoted passage from the open book, attached to a prompt the way Cursor
/// attaches a codebase reference.
public struct ChatReference: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var quotedText: String
    public var chapterTitle: String?
    public var spineIndex: Int

    public init(
        id: UUID = UUID(),
        quotedText: String,
        chapterTitle: String? = nil,
        spineIndex: Int
    ) {
        self.id = id
        self.quotedText = quotedText
        self.chapterTitle = chapterTitle
        self.spineIndex = spineIndex
    }

    /// Short label for chips in the composer and message list.
    public var preview: String {
        let trimmed = quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if trimmed.count <= 72 { return trimmed }
        return String(trimmed.prefix(72)) + "…"
    }
}
