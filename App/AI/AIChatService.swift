import Foundation

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
