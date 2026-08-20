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
    var startInDraw: Bool = false
    let onSave: (String) -> Void
    var onSaveDrawing: ((Data, Int) -> Void)? = nil
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    var onBack: (() -> Void)? = nil
    var onTogglePlacement: (() -> Void)? = nil
    var onRequestSheetForDraw: (() -> Void)? = nil

    @State private var text: String = ""
    @State private var selectedColor: HighlightColor = .yellow
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var mode: EditorMode = .edit
    @State private var saveWork: DispatchWorkItem?
    @State private var drawingWork: DispatchWorkItem?
    @State private var didOpenDraw = false
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if annotation.isOrphaned {
                orphanBanner
            }
            toolbar
            Divider()
            bodyEditor
            Divider()
            footer
        }
        .onAppear(perform: load)
        .onChange(of: text) { _, newValue in
            scheduleAutosave(newValue)
        }
        .onChange(of: mode) { _, newValue in
            handleModeChange(newValue)
        }
        .onDisappear(perform: flush)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if presentation == .sidebar, let onBack {
                    Button(action: onBack) {
                        Label("Notes", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .help("Back to notes")
                }

                Text(annotation.title)
                    .font(presentation == .sidebar ? .headline : .title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let onTogglePlacement {
                    Button(action: onTogglePlacement) {
                        Image(systemName: dockSymbol)
                            .font(.body.weight(.medium))
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(dockHelp)
                    .disabled(mode == .draw)
                }
            }

            HStack(spacing: 10) {
                if let chapter = annotation.chapterTitle {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
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
                                    selectedColor == color ? Color.accentColor : .black.opacity(0.15),
                                    lineWidth: selectedColor == color ? 2 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(color.displayName)
                }
            }
        }
        .padding(presentation == .sidebar ? 12 : 16)
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
                VStack(alignment: .leading, spacing: 8) {
                    formatButtons
                    modePicker
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 4) {
                    formatButtons
                    Spacer()
                    modePicker
                        .frame(width: 160)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var formatButtons: some View {
        HStack(spacing: 4) {
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
        }
        .disabled(mode == .preview)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(EditorMode.allCases) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var bodyEditor: some View {
        Group {
            if mode == .edit {
                MarkdownTextEditor(
                    text: $text,
                    selectedRange: $selectedRange,
                    placeholder: "Write your note…"
                )
                .padding(.horizontal, 4)
            } else {
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
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Delete Highlight", role: .destructive) {
                saveWork?.cancel()
                onDelete()
                onClose()
            }
            Spacer()
            Text("Autosaved")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Done") {
                flush()
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(presentation == .sidebar ? 12 : 16)
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
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.borderless)
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

    private func load() {
        text = annotation.note ?? ""
        selectedColor = annotation.color
        selectedRange = NSRange(location: (text as NSString).length, length: 0)
        if autofocus {
            mode = .edit
        }
    }

    private func flush() {
        saveWork?.cancel()
        onSave(text)
    }

    private func scheduleAutosave(_ value: String) {
        saveWork?.cancel()
        let work = DispatchWorkItem { onSave(value) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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
