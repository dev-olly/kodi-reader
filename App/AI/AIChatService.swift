import EpubKit
import Foundation

/// Errors from the OpenAI-compatible chat client.
enum AIChatError: LocalizedError {
    case noModel
    case missingKey(String)
    case invalidURL(String)
    case http(Int, String)
    case emptyResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noModel:
            return "Choose a model in Manage Models before asking."
        case .missingKey(let name):
            return "Add an API key for \(name) in Manage Models."
        case .invalidURL(let url):
            return "The model endpoint is not a valid URL: \(url)"
        case .http(let code, let body):
            let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.isEmpty {
                return "The model returned HTTP \(code)."
            }
            return "The model returned HTTP \(code): \(snippet.prefix(280))"
        case .emptyResponse:
            return "The model returned an empty reply."
        case .cancelled:
            return nil
        }
    }
}

/// Builds book-aware chat messages for an OpenAI-compatible endpoint.
struct AIChatService {
    struct Context {
        var bookTitle: String
        var author: String
        var chapterTitle: String?
    }

    func wireMessages(
        context: Context,
        history: [ChatMessage],
        userText: String,
        references: [ChatReference]
    ) -> [[String: String]] {
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt(context: context)],
        ]
        for turn in history {
            let role = turn.role == .user ? "user" : "assistant"
            let content: String
            if turn.role == .user, !turn.references.isEmpty {
                content = renderUserContent(text: turn.text, references: turn.references)
            } else {
                content = turn.text
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            messages.append(["role": role, "content": content])
        }
        messages.append([
            "role": "user",
            "content": renderUserContent(text: userText, references: references),
        ])
        return messages
    }

    func systemPrompt(context: Context) -> String {
        var lines = [
            "You are a reading assistant inside Kodi Reader, a native EPUB reader.",
            "The user is reading “\(context.bookTitle)” by \(context.author.isEmpty ? "an unknown author" : context.author).",
        ]
        if let chapter = context.chapterTitle, !chapter.isEmpty {
            lines.append("They are currently in the chapter “\(chapter)”.")
        }
        lines.append(
            "Answer questions using the quoted passages they attach as references. Be concise and helpful. If a quote is insufficient, say so rather than inventing context from outside the attached text."
        )
        return lines.joined(separator: "\n")
    }

    func renderUserContent(text: String, references: [ChatReference]) -> String {
        var parts: [String] = []
        if !references.isEmpty {
            parts.append("References from the book:")
            for reference in references {
                let quote = NoteMarkdown.blockquote(reference.quotedText)
                if let chapter = reference.chapterTitle, !chapter.isEmpty {
                    parts.append("From “\(chapter)”:")
                }
                parts.append(quote)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if !parts.isEmpty { parts.append("") }
            parts.append(trimmed)
        }
        return parts.joined(separator: "\n")
    }

}
