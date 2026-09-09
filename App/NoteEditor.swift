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
    let onSave: (String) -> Void
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
    @State private var didOpenDraw = false
    @State private var didLoadDrawingScene = false
    @State private var saveStatus: SaveStatus = .saved
    @State private var drawingController = ExcalidrawController()

    private enum EditorMode: String, CaseIterable, Identifiable {
        case edit
        case preview
        case draw
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edit: return "Edit"
            case .preview: return "Preview"
            case .draw: return "Draw"
            }
        }
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

    private var availableModes: [EditorMode] {
        presentation == .sidebar ? EditorMode.allCases : [.edit, .preview]
    }

    private var theme: ReaderTheme {
        isDark ? .dark : .light
    }

    private var horizontalPadding: CGFloat {
        presentation == .sidebar ? 18 : 40
    }

    private var editorBackground: Color {
        isDark ? theme.surface.opacity(0.55) : Color.white
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
                toolbar
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
                if presentation == .sheet {
                    windowDots
                }

                if presentation == .sidebar, let onBack {
                    Button(action: onBack) {
                        Label("Notes", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .help("Back to notes")
                }

                Text(presentation == .sheet ? "The lines you come back to" : "Margin note")
                    .font(.system(size: presentation == .sheet ? 17 : 13, weight: .medium))
                    .foregroundStyle(theme.uiForeground.opacity(presentation == .sheet ? 0.88 : 0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(presentation == .sheet ? .center : .leading)

                if presentation == .sheet {
                    Text("k.")
                        .font(.system(size: 24, weight: .regular, design: .serif))
                        .foregroundStyle(theme.uiForeground)
                        .frame(width: 58, alignment: .trailing)
                }

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
                    Text(chapter.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.1)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }

                quote

                colorRow
            }
            .padding(.top, presentation == .sheet ? 32 : 0)
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

    private var windowDots: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 1.0, green: 0.36, blue: 0.34))
                .frame(width: 9, height: 9)
            Circle()
                .fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                .frame(width: 9, height: 9)
            Circle()
                .fill(Color(red: 0.16, green: 0.78, blue: 0.25))
                .frame(width: 9, height: 9)
        }
        .frame(width: 58, height: 30, alignment: .leading)
        .frame(width: 58, alignment: .leading)
        .font(.system(size: 9))
    }

    private var quote: some View {
        Text(annotation.text)
            .font(.system(size: presentation == .sidebar ? 19 : 32, weight: .regular, design: .serif))
            .lineSpacing(presentation == .sidebar ? 5 : 7)
            .lineLimit(presentation == .sidebar ? 5 : 6)
            .textSelection(.enabled)
            .foregroundStyle(theme.uiForeground)
            .padding(.leading, 0)
            .background(alignment: .bottomLeading) {
                selectedColor.swiftUIColor
                    .opacity(isDark ? 0.34 : 0.58)
                    .frame(height: presentation == .sidebar ? 18 : 28)
                    .offset(y: presentation == .sidebar ? -2 : -5)
                    .allowsHitTesting(false)
            }
    }

    private var colorRow: some View {
        HStack(spacing: 10) {
            Text("Highlight")
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

    private var toolbar: some View {
        Group {
            if presentation == .sidebar {
                VStack(alignment: .leading, spacing: 10) {
                    if mode != .draw {
                        formatButtons
                    }
                    modePicker
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 12) {
                    if mode != .draw {
                        formatButtons
                    }
                    Spacer()
                    modePicker
                        .frame(width: 160)
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 14)
        .background(theme.surface.opacity(isDark ? 0.45 : 0.56))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border.opacity(0.72))
                .frame(height: 1)
        }
    }

    private var formatButtons: some View {
        HStack(spacing: 8) {
            formatButton("bold", help: "Bold") { wrap("**", "**") }
            formatButton("italic", help: "Italic") { wrap("*", "*") }
            formatButton("list.bullet", help: "Bulleted list") {
                prefixLines(with: "- ")
            }
            formatButton("list.number", help: "Numbered list") {
                prefixLines(with: "1. ")
            }
            formatButton("link", help: "Link") { wrap("[", "](url)") }
            formatButton("chevron.left.forwardslash.chevron.right", help: "Code block") {
                insertCodeBlock()
            }
            formatButton("tablecells", help: "Table") {
                insertTable()
            }
        }
        .disabled(mode == .preview)
        .padding(4)
        .background(editorBackground.opacity(isDark ? 0.28 : 0.72), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border.opacity(0.55), lineWidth: 1)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(availableModes) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
    }

    @ViewBuilder
    private var bodyEditor: some View {
        Group {
            switch mode {
            case .edit:
                MarkdownTextEditor(
                    text: $text,
                    selectedRange: $selectedRange,
                    placeholder: "Write your note…"
                )
                .padding(.horizontal, horizontalPadding - 8)
                .padding(.vertical, presentation == .sheet ? 26 : 16)
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
                    flushDrawingBeforeClose(teardown: false)
                }
                .font(.caption)
            }
            Button("Done") {
                flush()
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(theme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, presentation == .sheet ? 18 : 14)
        .background(theme.surface.opacity(isDark ? 0.54 : 0.72))
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

    // MARK: - Formatting

    private func formatButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 28)
        }
        .buttonStyle(QuietIconButtonStyle(theme: theme))
        .help(help)
    }

    private func wrap(_ prefix: String, _ suffix: String) {
        guard let range = Range(selectedRange, in: text) else { return }
        let result = NoteMarkdown.wrap(text, selection: range, prefix: prefix, suffix: suffix)
        text = result.text
        selectedRange = NSRange(result.selection, in: result.text)
    }

    private func prefixLines(with marker: String) {
        guard let range = Range(selectedRange, in: text) else {
            let end = text.endIndex
            let result = NoteMarkdown.prefixLines(text, selection: end..<end, marker: marker)
            text = result.text
            selectedRange = NSRange(result.selection, in: result.text)
            return
        }
        let result = NoteMarkdown.prefixLines(text, selection: range, marker: marker)
        text = result.text
        selectedRange = NSRange(result.selection, in: result.text)
    }

    private func insertCodeBlock() {
        guard let range = Range(selectedRange, in: text) else {
            let end = text.endIndex
            let result = NoteMarkdown.fenceCodeBlock(text, selection: end..<end)
            text = result.text
            selectedRange = NSRange(result.selection, in: result.text)
            return
        }
        let result = NoteMarkdown.fenceCodeBlock(text, selection: range)
        text = result.text
        selectedRange = NSRange(result.selection, in: result.text)
    }

    private func insertTable() {
        guard let range = Range(selectedRange, in: text) else {
            let end = text.endIndex
            let result = NoteMarkdown.insertTable(text, selection: end..<end)
            text = result.text
            selectedRange = NSRange(result.selection, in: result.text)
            return
        }
        let result = NoteMarkdown.insertTable(text, selection: range)
        text = result.text
        selectedRange = NSRange(result.selection, in: result.text)
    }

    private func load() {
        text = annotation.note ?? ""
        selectedColor = annotation.color
        selectedRange = NSRange(location: (text as NSString).length, length: 0)
        if autofocus {
            mode = .edit
        }
        wireDrawing()
        if mode == .draw {
            handleModeChange(.draw)
        }
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
        onSave(text)
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
        saveStatus = .saving
        saveWork?.cancel()
        let work = DispatchWorkItem {
            onSave(value)
            saveStatus = .saved
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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
    let onSave: (String) -> Void
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void
    var onTogglePlacement: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NoteEditor(
            annotation: annotation,
            autofocus: autofocus,
            presentation: .sheet,
            onSave: onSave,
            onChangeColor: onChangeColor,
            onDelete: onDelete,
            onClose: { dismiss() },
            onTogglePlacement: onTogglePlacement
        )
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 560)
    }
}
