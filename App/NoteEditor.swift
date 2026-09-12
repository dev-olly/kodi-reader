import Foundation
import EpubKit
import ReaderUI
import SwiftUI

/// Shared note editor used as a modal sheet or the trailing inspector.
struct NoteEditor: View {
    enum Presentation {
        case sheet
        case sidebar
    }

    let annotation: Annotation
    var autofocus: Bool = false
    var presentation: Presentation = .sheet
    var drawingScene: Data? = nil
    var isDark: Bool = false
    let onSave: (String, @escaping (Result<Void, Error>) -> Void) -> Void
    var onSaveDrawing: ((Data, Int, @escaping (Result<Void, Error>) -> Void) -> Void)? = nil
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    var onBack: (() -> Void)? = nil
    var onTogglePlacement: (() -> Void)? = nil
    var onDrawActiveChanged: ((Bool) -> Void)? = nil

    @State private var text: String = ""
    @State private var selectedColor: HighlightColor = .yellow
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var mode: EditorMode = .edit
    @State private var saveWork: DispatchWorkItem?
    @State private var drawingWork: DispatchWorkItem?
    @State private var didLoad = false
    @State private var didOpenDraw = false
    @State private var didLoadDrawingScene = false
    @State private var lastSavedText = ""
    @State private var saveRevision = 0
    @State private var sourceModeReason: String?
    @State private var saveStatus: SaveStatus = .saved
    @State private var drawingController = ExcalidrawController()

    private enum EditorMode {
        case edit
        case source
        case preview
        case draw
    }

    private enum SaveStatus: Equatable {
        case saving
        case saved
        case failed(String)

        var label: String {
            switch self {
            case .saving: return "Saving..."
            case .saved: return "Saved"
            case .failed(let message): return "Save failed: \(message)"
            }
        }

        var color: Color {
            switch self {
            case .saving: return .secondary
            case .saved: return .secondary.opacity(0.65)
            case .failed: return .red
            }
        }
    }

    private var theme: ReaderTheme {
        isDark ? .dark : .light
    }

    private var horizontalPadding: CGFloat {
        presentation == .sidebar ? 26 : 44
    }

    private var editorBackground: Color {
        isDark ? Color(red: 0.125, green: 0.145, blue: 0.133) : Color(red: 0.984, green: 0.988, blue: 0.976)
    }

    var body: some View {
        ZStack {
            theme.surface.opacity(presentation == .sheet ? 0.42 : 1)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                if annotation.isOrphaned {
                    orphanBanner
                }
                bodyEditor
                footer
            }
            .background(editorBackground)
            .overlay {
                RoundedRectangle(cornerRadius: presentation == .sheet ? 8 : 0)
                    .stroke(theme.border.opacity(presentation == .sheet ? 0.95 : 0), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: presentation == .sheet ? 8 : 0))
            .shadow(
                color: .black.opacity(presentation == .sheet && !isDark ? 0.08 : 0),
                radius: 28,
                y: 14
            )
            .padding(presentation == .sheet ? 28 : 0)
        }
        .onAppear(perform: load)
        .background(theme.surface)
        .foregroundStyle(theme.uiForeground)
        .colorScheme(theme.colorScheme)
        .onChange(of: text) { _, newValue in
            guard didLoad else { return }
            scheduleAutosave(newValue)
        }
        .onChange(of: mode) { _, newValue in
            handleModeChange(newValue)
        }
        .onChange(of: isDark) { _, newValue in
            drawingController.setTheme(newValue ? "dark" : "light")
        }
        .onDisappear(perform: flush)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: presentation == .sidebar ? 14 : 26) {
            HStack(alignment: .center, spacing: 12) {
                if presentation == .sidebar, let onBack {
                    Button(action: onBack) {
                        Label("Notes", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .help("Back to notes")
                }

                Text(presentation == .sheet ? "The lines you come back to" : "Your margin")
                    .font(.system(size: presentation == .sheet ? 13 : 11, weight: .medium))
                    .foregroundStyle(theme.uiForeground.opacity(presentation == .sheet ? 0.88 : 0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(presentation == .sheet ? .center : .leading)

                noteMenu

                if let onTogglePlacement {
                    Button(action: onTogglePlacement) {
                        Image(systemName: dockSymbol)
                            .font(.body.weight(.medium))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(QuietIconButtonStyle(theme: theme))
                    .help(dockHelp)
                    .disabled(mode == .draw)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                if let chapter = annotation.chapterTitle {
                    Text("HIGHLIGHT / " + chapter.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.1)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }

                quote

                colorRow
            }
            .padding(.top, presentation == .sheet ? 18 : 10)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, presentation == .sheet ? 26 : 18)
        .padding(.bottom, presentation == .sheet ? 24 : 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border.opacity(0.72))
                .frame(height: 1)
        }
    }

    private var quote: some View {
        Text(quoteAttributedString)
            .font(.system(size: presentation == .sidebar ? 20 : 28, weight: .regular, design: .serif))
            .lineSpacing(presentation == .sidebar ? 4 : 7)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var quoteAttributedString: AttributedString {
        var value = AttributedString(annotation.text)
        value.foregroundColor = theme.uiForeground
        if selectedColor == .underline {
            value.underlineStyle = .single
        } else {
            value.backgroundColor = selectedColor.swiftUIColor.opacity(isDark ? 0.28 : 0.40)
        }
        return value
    }

    private var colorRow: some View {
        HStack(spacing: 10) {
            Text("COLOR")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(theme.muted)

            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button {
                    selectedColor = color
                    onChangeColor(color)
                } label: {
                    Circle()
                        .fill(color == .underline ? Color.clear : color.swiftUIColor)
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle().strokeBorder(
                                selectedColor == color ? theme.accent : theme.border,
                                lineWidth: selectedColor == color ? 2 : 1
                            )
                        }
                        .overlay {
                            if color == .underline {
                                Capsule()
                                    .fill(theme.accent)
                                    .frame(width: 10, height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName + " highlight")
                .accessibilityAddTraits(selectedColor == color ? [.isSelected] : [])
            }
        }
    }

    private var orphanBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Quote not found in chapter. The note is kept; the highlight cannot be painted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var noteMenu: some View {
        Menu {
            Button("Write") {
                sourceModeReason = sourceModeFallbackReason(for: text)
                mode = sourceModeReason == nil ? .edit : .source
            }
            if presentation == .sidebar, onSaveDrawing != nil {
                Button("Draw") { mode = .draw }
            }
            Divider()
            Button("Markdown Source") { mode = .source }
            Button("Preview") { mode = .preview }
            Divider()
            Text("⌘B Bold · ⌘I Italic · ⌘U Underline")
            Text("⌘K Link · ⇧⌘X Strikethrough")
            Text("⌥⌘1 Heading · ⌥⌘0 Body")
            Text("⌥⌘7 Numbered list · ⌥⌘8 Bullets")
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 26, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Note options and keyboard shortcuts")
        .accessibilityLabel("Note options")
    }

    @ViewBuilder
    private var bodyEditor: some View {
        Group {
            switch mode {
            case .edit:
                writingSurface(source: false)
            case .source:
                VStack(alignment: .leading, spacing: 12) {
                    if let sourceModeReason {
                        unsupportedMarkdownBanner(sourceModeReason)
                    }
                    writingSurface(source: true)
                }
            case .preview:
                ScrollView {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing to preview yet.")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        NoteMarkdownPreview(text: text)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, presentation == .sheet ? 26 : 16)
            case .draw:
                ExcalidrawWebView(controller: drawingController)
                    .onAppear { drawingController.focusCanvas() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func writingSurface(source: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(source ? "MARKDOWN SOURCE" : "MY NOTE")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(theme.muted.opacity(0.72))
                .padding(.horizontal, 8)
            if source {
                MarkdownTextEditor(text: $text, selectedRange: $selectedRange,
                                   placeholder: "Write your note…")
            } else {
                RichNoteEditor(text: $text, isDark: isDark, autofocus: autofocus)
            }
        }
        .padding(.horizontal, horizontalPadding - 8)
        .padding(.top, presentation == .sheet ? 30 : 24)
        .padding(.bottom, 12)
    }

    private func unsupportedMarkdownBanner(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "curlybraces")
                .foregroundStyle(theme.accent)
            Text(reason)
                .font(.caption)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 14)
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                saveWork?.cancel()
                drawingWork?.cancel()
                onDelete()
                onClose()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(QuietIconButtonStyle(theme: theme, destructive: true))
            .help("Delete highlight")
            .accessibilityLabel("Delete highlight")
            Spacer()
            Text(saveStatus.label)
                .font(.caption2)
                .foregroundStyle(saveStatus.color)
                .lineLimit(1)
            if case .failed = saveStatus {
                Button("Retry") {
                    persistNote(text)
                    flushDrawingBeforeClose(teardown: false)
                }
                .font(.caption)
            }
            Button("Done") {
                flush()
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(theme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, presentation == .sheet ? 18 : 14)
        .background(editorBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border.opacity(0.72))
                .frame(height: 1)
        }
    }

    private var dockSymbol: String {
        presentation == .sheet ? "sidebar.right" : "macwindow"
    }

    private var dockHelp: String {
        presentation == .sheet ? "Open in Sidebar" : "Open as Window"
    }

    private func load() {
        text = annotation.note ?? ""
        lastSavedText = text
        sourceModeReason = sourceModeFallbackReason(for: text)
        selectedColor = annotation.color
        selectedRange = NSRange(location: (text as NSString).length, length: 0)
        if sourceModeReason != nil {
            mode = .source
        } else if autofocus {
            mode = .edit
        }
        wireDrawing()
        if mode == .draw {
            handleModeChange(.draw)
        }
        didLoad = true
    }

    private func handleModeChange(_ newValue: EditorMode) {
        onDrawActiveChanged?(newValue == .draw)
        guard newValue == .draw else { return }
        didOpenDraw = true
        drawingController.setTheme(isDark ? "dark" : "light")
        guard !didLoadDrawingScene else { return }
        didLoadDrawingScene = true
        drawingController.load(scene: drawingScene)
    }

    private func wireDrawing() {
        drawingController.onSceneChanged = { count, data in
            scheduleDrawingSave(data, elementCount: count)
        }
        drawingController.onError = { message in
            saveStatus = .failed(message)
        }
    }

    private func flush() {
        saveWork?.cancel()
        persistNote(text)
        drawingWork?.cancel()
        onDrawActiveChanged?(false)
        flushDrawingBeforeClose(teardown: true)
    }

    private func flushDrawingBeforeClose(teardown: Bool) {
        guard didOpenDraw, let onSaveDrawing else {
            if teardown { drawingController.tearDown() }
            return
        }
        saveStatus = .saving
        drawingController.pullScene { count, data in
            if let data {
                onSaveDrawing(data, count) { result in
                    switch result {
                    case .success:
                        saveStatus = .saved
                        if teardown { drawingController.tearDown() }
                    case .failure(let error):
                        saveStatus = .failed(error.localizedDescription)
                        if teardown { drawingController.tearDown() }
                    }
                }
            } else {
                saveStatus = .failed("The drawing surface was not ready.")
                if teardown { drawingController.tearDown() }
            }
        }
    }

    private func scheduleAutosave(_ value: String) {
        saveWork?.cancel()
        guard value != lastSavedText else {
            saveStatus = .saved
            return
        }
        saveStatus = .saving
        let work = DispatchWorkItem {
            persistNote(value)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persistNote(_ value: String) {
        guard value != lastSavedText else {
            saveStatus = .saved
            return
        }
        saveRevision += 1
        let revision = saveRevision
        saveStatus = .saving
        onSave(value) { result in
            guard revision == saveRevision else { return }
            switch result {
            case .success:
                lastSavedText = value
                saveStatus = .saved
            case .failure(let error):
                saveStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func sourceModeFallbackReason(for markdown: String) -> String? {
        let constructs = NoteMarkdown.unsupportedConstructs(in: markdown.replacingOccurrences(of: "</?u>", with: "", options: .regularExpression))
        if let reason = RichNoteCodec.sourceOnlyReason(markdown) {
            return "This note contains \(reason). Markdown source keeps its formatting intact."
        }
        guard !constructs.isEmpty else { return nil }
        let labels = constructs.map(\.label).joined(separator: ", ")
        return "This note contains \(labels), so it opens in Markdown source mode to preserve the original text."
    }

    private func scheduleDrawingSave(_ data: Data, elementCount: Int) {
        saveStatus = .saving
        drawingWork?.cancel()
        let work = DispatchWorkItem {
            onSaveDrawing?(data, elementCount) { result in
                switch result {
                case .success:
                    saveStatus = .saved
                case .failure(let error):
                    saveStatus = .failed(error.localizedDescription)
                }
            }
        }
        drawingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

private struct QuietIconButtonStyle: ButtonStyle {
    let theme: ReaderTheme
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? Color.red.opacity(0.9) : theme.uiForeground.opacity(0.86))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(background(configuration: configuration))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }

    private func background(configuration: Configuration) -> Color {
        if configuration.isPressed {
            return theme.accent.opacity(theme.isDark ? 0.22 : 0.12)
        }
        return Color.clear
    }
}

/// Modal wrapper around `NoteEditor`.
struct NoteSheet: View {
    let annotation: Annotation
    var autofocus: Bool = false
    var isDark: Bool = false
    let onSave: (String, @escaping (Result<Void, Error>) -> Void) -> Void
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void
    var onTogglePlacement: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NoteEditor(
            annotation: annotation,
            autofocus: autofocus,
            presentation: .sheet,
            isDark: isDark,
            onSave: onSave,
            onChangeColor: onChangeColor,
            onDelete: onDelete,
            onClose: { dismiss() },
            onTogglePlacement: onTogglePlacement
        )
        .frame(minWidth: 520, idealWidth: 580, minHeight: 560, idealHeight: 640)
    }
}
