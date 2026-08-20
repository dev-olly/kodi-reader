import EpubKit
import SwiftUI

/// Cursor-style chat docked on the leading edge of the reader.
struct AskAIPanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var composerFocused: Bool
    @State private var bottomID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if let error = model.chat.errorMessage, !error.isEmpty {
                errorBanner(error)
            }
            Divider()
            composer
        }
        .background(.background)
        .onChange(of: model.chat.shouldFocusComposer) { _, should in
            if should {
                composerFocused = true
                model.chat.shouldFocusComposer = false
            }
        }
        .onChange(of: model.chat.messages.count) { _, _ in
            bottomID = UUID()
        }
        .onAppear {
            if model.chat.shouldFocusComposer {
                composerFocused = true
                model.chat.shouldFocusComposer = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Ask AI")
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    model.chat.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New chat")
                .disabled(model.chat.messages.isEmpty && model.chat.input.isEmpty)

                Button {
                    model.isShowingManageModels = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Manage models")
            }

            if model.aiConfig.configs.isEmpty {
                Button("Add a model…") {
                    model.isShowingManageModels = true
                }
                .font(.caption)
            } else {
                Picker("Model", selection: selectedModelBinding) {
                    ForEach(model.aiConfig.configs) { config in
                        Text(config.name).tag(config.id as UUID?)
                    }
                }
                .labelsHidden()
            }
        }
        .padding(12)
    }

    private var selectedModelBinding: Binding<UUID?> {
        Binding(
            get: { model.aiConfig.selectedModelID },
            set: { model.aiConfig.selectedModelID = $0 }
        )
    }

    // MARK: - Messages

    private var messageList: some View {
        Group {
            if model.chat.messages.isEmpty {
                ContentUnavailableView(
                    "Ask about this book",
                    systemImage: "sparkles",
                    description: Text("Select a passage and press ⌘L to attach it, then ask a question.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.chat.messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                        }
                        .padding(12)
                    }
                    .onChange(of: model.chat.messages.last?.text) { _, _ in
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                    .onChange(of: bottomID) { _, id in
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.references.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.references) { reference in
                        referenceChip(reference, removable: false)
                    }
                }
            }

            if message.role == .assistant {
                if message.text.isEmpty, model.chat.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    NoteMarkdownPreview(text: message.text)
                        .textSelection(.enabled)
                }
            } else {
                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            message.role == .user
                ? Color.primary.opacity(0.06)
                : Color.clear,
            in: .rect(cornerRadius: 8)
        )
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                model.chat.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var composer: some View {
        Color.clear.frame(height: 1)
    }
}
