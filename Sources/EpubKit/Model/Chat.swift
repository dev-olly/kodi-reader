import Foundation

/// Who wrote a turn in the Ask AI conversation.
public enum ChatRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
}
