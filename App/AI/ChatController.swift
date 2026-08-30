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

    /// Saved threads for the open book, newest first.
    private(set) var threads: [ChatThread] = []
    private(set) var activeThreadID: UUID?

    /// Called after the conversation changes so AppModel can write the book record.
    var onPersist: (([ChatThread], UUID?) -> Void)?
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

    func updateReference(_ id: UUID, contextBefore: String?, contextAfter: String?) {
        if let index = pendingReferences.firstIndex(where: { $0.id == id }) {
            pendingReferences[index].contextBefore = contextBefore
            pendingReferences[index].contextAfter = contextAfter
        }
        if let messageIndex = messages.lastIndex(where: {
            $0.role == .user && $0.references.contains(where: { $0.id == id })
        }), let refIndex = messages[messageIndex].references.firstIndex(where: { $0.id == id }) {
            messages[messageIndex].references[refIndex].contextBefore = contextBefore
            messages[messageIndex].references[refIndex].contextAfter = contextAfter
            persist()
        }
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
        let key = APIKeyStore.get(account: config.id.uuidString)
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

    func newConversation() {
        stop()
        syncActiveThread()
        guard !messages.isEmpty else {
            shouldFocusComposer = true
            return
        }
        messages = []
        input = ""
        pendingReferences = []
        errorMessage = nil
        activeThreadID = nil
        persist()
        shouldFocusComposer = true
    }

    func selectThread(_ id: UUID) {
        guard id != activeThreadID else { return }
        stop()
        syncActiveThread()
        guard let thread = threads.first(where: { $0.id == id }) else { return }
        activeThreadID = thread.id
        messages = thread.messages
        input = ""
        pendingReferences = []
        errorMessage = nil
        persist()
        shouldFocusComposer = true
    }

    func deleteThread(_ id: UUID) {
        stop()
        threads.removeAll { $0.id == id }
        if activeThreadID == id {
            if let next = threads.first {
                activeThreadID = next.id
                messages = next.messages
            } else {
                activeThreadID = nil
                messages = []
            }
        }
        input = ""
        pendingReferences = []
        persist()
    }

    /// Restore a book's threads without writing back.
    func load(threads stored: [ChatThread], activeID: UUID?) {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        threads = stored.sorted { $0.updatedAt > $1.updatedAt }
        if let activeID, let thread = threads.first(where: { $0.id == activeID }) {
            activeThreadID = thread.id
            messages = thread.messages
        } else if let latest = threads.first {
            activeThreadID = latest.id
            messages = latest.messages
        } else {
            activeThreadID = nil
            messages = []
        }
        input = ""
        pendingReferences = []
        errorMessage = nil
        shouldFocusComposer = false
    }

    /// Clear in-memory state without persisting — used when closing a book.
    func detach() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        messages = []
        input = ""
        pendingReferences = []
        errorMessage = nil
        shouldFocusComposer = false
    }

    private func persist() {
        onPersist?(messages)
    }
}
