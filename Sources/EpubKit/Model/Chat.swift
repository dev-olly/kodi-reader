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
    /// Paragraphs immediately before the quote, if the reader could extract them.
    public var contextBefore: String?
    /// Paragraphs immediately after the quote, if the reader could extract them.
    public var contextAfter: String?

    public init(
        id: UUID = UUID(),
        quotedText: String,
        chapterTitle: String? = nil,
        spineIndex: Int,
        contextBefore: String? = nil,
        contextAfter: String? = nil
    ) {
        self.id = id
        self.quotedText = quotedText
        self.chapterTitle = chapterTitle
        self.spineIndex = spineIndex
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }

    public var hasSurroundingContext: Bool {
        let before = contextBefore?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let after = contextAfter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !before.isEmpty || !after.isEmpty
    }

    /// Short label for chips in the composer and message list.
    public var preview: String {
        let trimmed = quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if trimmed.count <= 72 { return trimmed }
        return String(trimmed.prefix(72)) + "…"
    }
}

/// One turn in a book's Ask AI conversation.
public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var text: String
    public var references: [ChatReference]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        references: [ChatReference] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.references = references
        self.createdAt = createdAt
    }
}
