import EpubKit
import SwiftUI

/// Full note editor: quote as title, markdown body with toolbar, autosave.
struct NoteSheet: View {
    let annotation: Annotation
    var autofocus: Bool = false
    let onSave: (String) -> Void
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void

    @State private var text: String = ""
    @State private var selectedColor: HighlightColor = .yellow
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var mode: EditorMode = .edit
    @State private var saveWork: DispatchWorkItem?
    @Environment(\.dismiss) private var dismiss

    private enum EditorMode: String, CaseIterable, Identifiable {
        case edit
        case preview
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edit: return "Edit"
            case .preview: return "Preview"
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
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 560)
        .onAppear {
            text = annotation.note ?? ""
            selectedColor = annotation.color
            if autofocus {
                mode = .edit
            }
        }
        .onChange(of: text) { _, newValue in
            scheduleAutosave(newValue)
        }
        .onDisappear {
            saveWork?.cancel()
            onSave(text)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(annotation.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if let chapter = annotation.chapterTitle {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
        .padding(16)
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
        HStack(spacing: 4) {
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

            Spacer()

            Picker("Mode", selection: $mode) {
                ForEach(EditorMode.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bodyEditor: some View {
        Group {
            if mode == .edit {
                MarkdownTextEditor(text: $text, selectedRange: $selectedRange)
                    .padding(.horizontal, 4)
            } else {
                ScrollView {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing to preview yet.")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        notePreview
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if mode == .edit && text.isEmpty {
                Text("Write your note…")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    private var notePreview: some View {
        NoteMarkdownPreview(text: text)
    }

    private var footer: some View {
        HStack {
            Button("Delete Highlight", role: .destructive) {
                saveWork?.cancel()
                onDelete()
                dismiss()
            }
            Spacer()
            Text("Autosaved")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Done") {
                saveWork?.cancel()
                onSave(text)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
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

    private func scheduleAutosave(_ value: String) {
        saveWork?.cancel()
        let work = DispatchWorkItem { onSave(value) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
