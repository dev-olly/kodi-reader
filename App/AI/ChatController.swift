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

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let config = configStore.selectedConfig else {
            errorMessage = AIChatError.noModel.localizedDescription
            return
        }

        let references = pendingReferences
        input = ""
        pendingReferences = []
        errorMessage = nil

        let history = messages
        let userMessage = ChatMessage(role: .user, text: text, references: references)
        messages.append(userMessage)
        persist()

        let assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        isStreaming = true
        let key = KeychainStore.get(account: config.id.uuidString)
        let context = contextProvider()

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = self.service.stream(
                    config: config,
                    apiKey: key,
                    context: context,
                    history: history,
                    userText: text,
                    references: references
                )
                for try await token in stream {
                    if Task.isCancelled { break }
                    if let index = self.messages.lastIndex(where: { $0.id == assistant.id }) {
                        self.messages[index].text += token
                    }
                }
            } catch is CancellationError {
                // Stop is intentional.
            } catch AIChatError.cancelled {
                // Stop is intentional.
            } catch {
                self.errorMessage = error.localizedDescription
                if let index = self.messages.lastIndex(where: { $0.id == assistant.id }),
                   self.messages[index].text.isEmpty {
                    self.messages.remove(at: index)
                }
            }
            self.isStreaming = false
            self.streamTask = nil
            self.persist()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        persist()
    }

    private func persist() {
        onPersist?(messages)
    }
}
