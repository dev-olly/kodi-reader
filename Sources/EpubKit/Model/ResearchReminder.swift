import Foundation

/// A research task saved without leaving the current book or note.
public struct ResearchReminder: Codable, Identifiable, Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable {
        case selection, page, note
    }

    public var id: UUID
    public var title: String
    public var source: Source
    /// Independent of the source annotation so the task remains useful if it is deleted.
    public var locator: Locator
    public var quotedText: String
    public var chapterTitle: String?
    public var annotationID: UUID?
    public var createdAt: Date
    public var modifiedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        source: Source = .selection,
        locator: Locator,
        quotedText: String = "",
        chapterTitle: String? = nil,
        annotationID: UUID? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.locator = locator
        self.quotedText = quotedText
        self.chapterTitle = chapterTitle
        self.annotationID = annotationID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.completedAt = completedAt
    }

    public var isCompleted: Bool { completedAt != nil }
}
