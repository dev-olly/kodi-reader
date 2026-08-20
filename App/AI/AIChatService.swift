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

/// Streams chat completions from any OpenAI-compatible `/chat/completions` endpoint.
struct AIChatService {
    struct Context {
        var bookTitle: String
        var author: String
        var chapterTitle: String?
    }

    func stream(
        config: AIModelConfig,
        apiKey: String?,
        context: Context,
        history: [ChatMessage],
        userText: String,
        references: [ChatReference]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        config: config,
                        apiKey: apiKey,
                        context: context,
                        history: history,
                        userText: userText,
                        references: references,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIChatError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func run(
        config: AIModelConfig,
        apiKey: String?,
        context: Context,
        history: [ChatMessage],
        userText: String,
        references: [ChatReference],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let url = chatCompletionsURL(from: config.baseURL) else {
            throw AIChatError.invalidURL(config.baseURL)
        }

        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if config.requiresKey, key.isEmpty {
            throw AIChatError.missingKey(config.name)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Kodi Reader", forHTTPHeaderField: "X-Title")
        request.setValue("https://github.com/olly/kodi-reader", forHTTPHeaderField: "HTTP-Referer")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": config.modelID,
            "stream": true,
            "messages": wireMessages(
                context: context,
                history: history,
                userText: userText,
                references: references
            ),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if Task.isCancelled { throw CancellationError() }

        guard let http = response as? HTTPURLResponse else {
            throw AIChatError.http(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body.append(line)
                body.append("\n")
                if body.count > 2_000 { break }
            }
            throw AIChatError.http(http.statusCode, decodedHTTPError(body))
        }

        var receivedAny = false
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let data = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data.isEmpty { continue }
            if data == "[DONE]" { break }
            if let errorText = sseError(data) {
                throw AIChatError.http(http.statusCode, errorText)
            }
            if let token = sseDelta(data), !token.isEmpty {
                receivedAny = true
                continuation.yield(token)
            }
        }

        if !receivedAny {
            throw AIChatError.emptyResponse
        }
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

    private func chatCompletionsURL(from base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/chat/completions")
    }

    private func sseDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first
        else { return nil }

        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String { return content }
            // Some local servers nest the token under `text`.
            if let text = delta["text"] as? String { return text }
        }
        if let text = first["text"] as? String { return text }
        return nil
    }

    private func sseError(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String ?? "Model error"
        }
        if let error = object["error"] as? String {
            return error
        }
        return nil
    }

    private func decodedHTTPError(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return trimmed }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = object["message"] as? String {
            return message
        }
        return trimmed
    }
}
