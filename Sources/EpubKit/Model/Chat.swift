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

/// One saved Ask AI conversation for a book, like a Cursor chat thread.
public struct ChatThread: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "New chat",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func title(from messages: [ChatMessage]) -> String {
        let text = messages.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) ?? ""
        if text.isEmpty { return "New chat" }
        if text.count <= 48 { return text }
        return String(text.prefix(48)) + "…"
    }

    public static func wrappingLegacyMessages(_ messages: [ChatMessage]) -> ChatThread {
        let stamp = messages.last?.createdAt ?? Date()
        return ChatThread(
            title: title(from: messages),
            messages: messages,
            createdAt: messages.first?.createdAt ?? stamp,
            updatedAt: stamp
        )
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
