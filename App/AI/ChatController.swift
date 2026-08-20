import EpubKit
import Foundation
import Observation

/// Owns the Ask AI conversation: references, streaming replies, and persistence.
@MainActor
@Observable
final class ChatController {
    var messages: [ChatMessage] = []
    var input: String = ""
    var pendingReferences: [ChatReference] = []
    var isStreaming = false
    var errorMessage: String?
    /// Set by the panel so Cmd+L can park the caret in the composer.
    var shouldFocusComposer = false

    /// Called after the conversation changes so AppModel can write the book record.
    var onPersist: (([ChatMessage]) -> Void)?
    /// Live book metadata for the system prompt.
    var contextProvider: () -> AIChatService.Context = {
        AIChatService.Context(bookTitle: "", author: "", chapterTitle: nil)
    }

    @ObservationIgnored let configStore: AIConfigStore
    @ObservationIgnored private let service = AIChatService()
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    init(configStore: AIConfigStore) {
        self.configStore = configStore
    }

    var canSend: Bool {
        !isStreaming
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && configStore.selectedConfig != nil
    }

    func addReference(_ reference: ChatReference) {
        let quote = reference.quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return }
        if pendingReferences.contains(where: { $0.quotedText == reference.quotedText }) {
            shouldFocusComposer = true
            return
        }
        pendingReferences.append(reference)
        shouldFocusComposer = true
        errorMessage = nil
    }

    func removePendingReference(_ id: UUID) {
        pendingReferences.removeAll { $0.id == id }
    }
}
