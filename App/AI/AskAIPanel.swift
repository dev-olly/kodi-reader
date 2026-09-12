import EpubKit
import SwiftUI

/// Conversation surface in the shared reading workspace.
struct AskAIPanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var composerFocused: Bool
    @State private var bottomID = UUID()
    @State private var showingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            if let error = model.chat.errorMessage, !error.isEmpty {
                errorBanner(error)
            }
            composer
        }
        .background(model.settings.theme.uiBackground)
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
            if model.isShowingAskAI, model.chat.shouldFocusComposer {
                composerFocused = true
                model.chat.shouldFocusComposer = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask AI")
                        .font(.system(size: 24, weight: .regular, design: .serif))
                        .foregroundStyle(model.settings.theme.uiForeground)
                    Text(model.chat.messages.isEmpty ? "A fresh thread" : "\(model.chat.messages.count) messages")
                        .font(.caption)
                        .foregroundStyle(model.settings.theme.muted)
                }

                Spacer(minLength: 8)

                HStack(spacing: 2) {
                    headerIcon(
                        "clock",
                        help: "Chat history",
                        disabled: model.chat.threads.isEmpty
                    ) {
                        showingHistory.toggle()
                    }
                    .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                        historyList
                    }

                    headerIcon(
                        "square.and.pencil",
                        help: "New chat",
                        disabled: model.chat.messages.isEmpty && model.chat.input.isEmpty
                    ) {
                        showingHistory = false
                        model.chat.newConversation()
                    }

                }
                .padding(3)
                .background(model.settings.theme.surface, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(model.settings.theme.border.opacity(0.8), lineWidth: 1)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.settings.theme.accent)
                Text("Kodi AI")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("OpenAI")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.settings.theme.muted)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(model.settings.theme.uiForeground)
            .background(model.settings.theme.surface, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(model.settings.theme.border, lineWidth: 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background {
            model.settings.theme.uiBackground
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(model.settings.theme.border.opacity(0.8))
                        .frame(height: 1)
                }
        }
    }

    private func headerIcon(
        _ systemName: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? model.settings.theme.muted.opacity(0.4) : model.settings.theme.muted)
        .disabled(disabled)
        .help(help)
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chats in this book")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if model.chat.threads.isEmpty {
                Text("No previous chats")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List {
                    ForEach(model.chat.threads) { thread in
                        Button {
                            model.chat.selectThread(thread.id)
                            showingHistory = false
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(thread.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if thread.id == model.chat.activeThreadID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                model.chat.deleteThread(thread.id)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            model.chat.deleteThread(model.chat.threads[index].id)
                        }
                    }
                }
                .frame(minWidth: 260, minHeight: 220)
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 260, minHeight: 120)
    }

    // MARK: - Messages

    private var messageList: some View {
        Group {
            if model.chat.messages.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Spacer(minLength: 8)
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "quote.bubble.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(model.settings.theme.accent)
                        Text("What caught your attention?")
                            .font(.system(size: 27, weight: .regular, design: .serif))
                            .foregroundStyle(model.settings.theme.uiForeground)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Bring a passage here, or ask from where you are.")
                            .font(.system(size: 13))
                            .foregroundStyle(model.settings.theme.muted)
                            .lineSpacing(3)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        promptSuggestion("Explain the argument in this section")
                        promptSuggestion("What is the author implying here?")
                        promptSuggestion("Turn this into a note I can keep")
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 26)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(model.chat.messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                        }
                        .padding(20)
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

    private func promptSuggestion(_ text: String) -> some View {
        Button {
            model.chat.input = text
            composerFocused = true
        } label: {
            HStack(spacing: 8) {
                Text(text)
                    .font(.system(size: 12))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.settings.theme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.settings.theme.uiForeground)
        .background(model.settings.theme.surface, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(model.settings.theme.border.opacity(0.8), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !message.references.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.references) { reference in
                        referenceChip(reference, removable: false)
                    }
                }
            }

            if message.role == .assistant {
                Label("KODI AI", systemImage: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.settings.theme.accent)
                if message.text.isEmpty, model.chat.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    NoteMarkdownPreview(text: message.text)
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                }
            } else {
                Text(message.text)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: 260, alignment: .leading)
                    .padding(12)
                    .background(model.settings.theme.surface, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(model.settings.theme.border.opacity(0.7), lineWidth: 1)
                    }
            }
        }
        .padding(.leading, message.role == .assistant ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: message.role == .assistant ? .leading : .trailing)
        .overlay(alignment: .leading) {
            if message.role == .assistant {
                Rectangle().fill(model.settings.theme.accent.opacity(0.45)).frame(width: 2)
            }
        }
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

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.chat.pendingReferences.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.chat.pendingReferences) { reference in
                        referenceChip(reference, removable: true)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this book…", text: inputBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit {
                        model.chat.send()
                    }

                if model.chat.isStreaming {
                    Button {
                        model.chat.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.settings.theme.accent)
                    .help("Stop")
                } else {
                    Button {
                        model.chat.send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(model.settings.theme.uiBackground)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(model.chat.canSend ? model.settings.theme.accent : model.settings.theme.muted.opacity(0.35))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.chat.canSend)
                    .help("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(model.settings.theme.uiBackground, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(composerFocused ? model.settings.theme.accent : model.settings.theme.border, lineWidth: 1)
            }
        }
        .padding(14)
        .background {
            model.settings.theme.surface
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(model.settings.theme.border.opacity(0.8))
                        .frame(height: 1)
                }
        }
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { model.chat.input },
            set: { model.chat.input = $0 }
        )
    }

    private func referenceChip(_ reference: ChatReference, removable: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if let chapter = reference.chapterTitle, !chapter.isEmpty {
                    Text(chapter)
                        .font(.caption2)
                        .foregroundStyle(model.settings.theme.muted)
                        .lineLimit(1)
                }
                Text(reference.preview)
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(model.settings.theme.uiForeground)
                    .lineSpacing(5)
                    .lineLimit(removable ? 3 : 5)
                if reference.hasSurroundingContext {
                    Text("with nearby paragraphs")
                        .font(.caption2)
                        .foregroundStyle(model.settings.theme.muted)
                }
            }
            Spacer(minLength: 0)
            if removable {
                Button {
                    model.chat.removePendingReference(reference.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove reference")
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.yellow.opacity(0.65)).frame(width: 3)
        }
    }
}
