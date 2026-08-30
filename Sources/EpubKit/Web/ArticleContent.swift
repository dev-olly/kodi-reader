import Foundation

public enum ArticleError: LocalizedError, Equatable {
    case invalidURL
    case extractionFailed(String)
    case emptyArticle
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn’t look like a web address."
        case let .extractionFailed(message):
            return message
        case .emptyArticle:
            return "Could not extract an article from this page."
        case let .writeFailed(message):
            return "Could not save the page: \(message)"
        }
    }
}

/// A reader-mode article extracted from a live webpage.
public struct ArticleContent: Sendable, Equatable {
    public var title: String
    public var byline: String?
    public var sourceURL: URL
    public var contentHTML: String
    public var language: String?

    public init(
        title: String,
        byline: String? = nil,
        sourceURL: URL,
        contentHTML: String,
        language: String? = nil
    ) {
        self.title = title
        self.byline = byline
        self.sourceURL = sourceURL
        self.contentHTML = contentHTML
        self.language = language
    }

    public var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return sourceURL.host ?? sourceURL.absoluteString
    }

    public var resolvedAuthor: String {
        let trimmed = (byline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return sourceURL.host ?? "Web"
    }
}
