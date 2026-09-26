import AppKit
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
        .background(model.settings.theme.surface)
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
                        model.aiNoteTarget = nil
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
                AIAccountMenu(auth: model.aiAuth).font(.caption)
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
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background {
            model.settings.theme.surface
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
                    SelectableAIAnswer(
                        markdown: message.text
                    )
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

/// A single AI answer with one contextual action: select text, then add that
/// selection to the note that opened Ask AI.
private struct SelectableAIAnswer: View {
    let markdown: String

    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var clearSelectionToken = 0
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var addedConfirmation = false
    @State private var confirmationGeneration = 0

    var body: some View {
        SelectableAIText(
            markdown: markdown,
            isDark: model.settings.theme.isDark,
            clearSelectionToken: clearSelectionToken,
            onSelectionChange: { selected in
                selection = selected
                saveError = nil
                if selected != nil {
                    addedConfirmation = false
                }
            }
        )
        .overlay(alignment: .topTrailing) {
            if let selection, canAddToNote {
                VStack(alignment: .trailing, spacing: 4) {
                    Button {
                        addToNote(selection)
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Add to note", systemImage: "note.text.badge.plus")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSaving)

                    if let saveError {
                        Text(saveError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: .rect(cornerRadius: 6))
                    }
                }
                .padding(4)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            } else if addedConfirmation {
                Label("Added to note", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: .rect(cornerRadius: 7))
                    .padding(4)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: canAddToNote)
        .animation(.easeOut(duration: 0.12), value: addedConfirmation)
    }

    private var canAddToNote: Bool {
        switch model.aiNoteTarget {
        case .annotation(let id):
            return model.annotation(with: id) != nil
        case .selection:
            return true
        case nil:
            return false
        }
    }

    private func addToNote(_ selection: String) {
        guard let target = model.aiNoteTarget else { return }
        isSaving = true
        saveError = nil
        switch target {
        case .annotation(let id):
            model.appendKodiExcerpt(selection, to: id) { result in
                finishSaving(result.map { id })
            }
        case .selection(let bookSelection, let chapterTitle):
            model.createKodiNote(
                from: selection,
                for: bookSelection,
                chapterTitle: chapterTitle,
                completion: finishSaving
            )
        }
    }

    private func finishSaving(_ result: Result<UUID, Error>) {
        isSaving = false
        switch result {
        case .success:
            self.selection = nil
            clearSelectionToken += 1
            showAddedConfirmation()
        case .failure(let error):
            saveError = error.localizedDescription
        }
    }

    private func showAddedConfirmation() {
        confirmationGeneration += 1
        let generation = confirmationGeneration
        addedConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if generation == confirmationGeneration {
                addedConfirmation = false
            }
        }
    }
}

/// AppKit supplies the selected range that SwiftUI's Text selection API does
/// not expose. The view remains read-only and sizes itself to its answer.
private struct SelectableAIText: NSViewRepresentable {
    let markdown: String
    let isDark: Bool
    let clearSelectionToken: Int
    let onSelectionChange: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: textView.bounds.width,
            height: .greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("AI answer")

        context.coordinator.textView = textView
        context.coordinator.update(markdown: markdown, isDark: isDark)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(markdown: markdown, isDark: isDark)
        if context.coordinator.lastClearSelectionToken != clearSelectionToken {
            context.coordinator.lastClearSelectionToken = clearSelectionToken
            context.coordinator.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        let width = max(1, proposal.width ?? nsView.bounds.width)
        nsView.frame.size.width = width
        nsView.textContainer?.containerSize = NSSize(
            width: width,
            height: .greatestFiniteMagnitude
        )
        guard let layoutManager = nsView.layoutManager,
              let textContainer = nsView.textContainer
        else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height)
        nsView.frame.size.height = max(18, height)
        return CGSize(width: width, height: max(18, height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableAIText
        weak var textView: NSTextView?
        var renderedMarkdown: String?
        var renderedIsDark: Bool?
        var lastClearSelectionToken: Int

        init(_ parent: SelectableAIText) {
            self.parent = parent
            lastClearSelectionToken = parent.clearSelectionToken
        }

        func update(markdown: String, isDark: Bool) {
            guard renderedMarkdown != markdown || renderedIsDark != isDark,
                  let textView
            else { return }
            renderedMarkdown = markdown
            renderedIsDark = isDark
            textView.textStorage?.setAttributedString(Self.render(markdown, isDark: isDark))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            let selected: String?
            if range.length > 0 {
                let value = (textView.string as NSString).substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                selected = value.isEmpty ? nil : value
            } else {
                selected = nil
            }
            DispatchQueue.main.async { [parent] in
                parent.onSelectionChange(selected)
            }
        }

        private static func render(_ markdown: String, isDark: Bool) -> NSAttributedString {
            let value = NSMutableAttributedString(
                attributedString: RichNoteCodec.decode(markdown, dark: isDark)
            )
            let fullRange = NSRange(location: 0, length: value.length)
            value.enumerateAttribute(.font, in: fullRange) { fontValue, range, _ in
                let original = fontValue as? NSFont ?? .systemFont(ofSize: 13)
                let traits = original.fontDescriptor.symbolicTraits
                var font: NSFont = traits.contains(.monoSpace)
                    ? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
                    : .systemFont(ofSize: 13)
                if traits.contains(.bold) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if traits.contains(.italic) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                value.addAttribute(.font, value: font, range: range)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 8
            value.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
            return value
        }
    }
}
