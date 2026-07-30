import EpubKit
import SwiftUI

/// Colour picker shown next to a fresh selection, plus a way to open a note.
struct HighlightPalette: View {
    let onPick: (HighlightColor) -> Void
    let onAddNote: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button { onPick(color) } label: {
                    swatch(for: color)
                }
                .buttonStyle(.plain)
                .help(color.displayName)
            }

            Divider().frame(height: 20)

            Button(action: onAddNote) {
                Label("Note", systemImage: "text.badge.plus")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Highlight and add a note")

            Divider().frame(height: 20)

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .shadow(radius: 8, y: 3)
    }

    @ViewBuilder
    private func swatch(for color: HighlightColor) -> some View {
        if color == .underline {
            VStack(spacing: 2) {
                Text("A").font(.system(size: 12, weight: .semibold))
                Rectangle().frame(height: 2)
            }
            .frame(width: 20, height: 20)
            .foregroundStyle(.primary)
        } else {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 20, height: 20)
                .overlay { Circle().strokeBorder(.black.opacity(0.12)) }
        }
    }
}

/// Note editor shown when creating or editing a highlight's note.
struct NoteEditor: View {
    let annotation: Annotation
    var autofocus: Bool = false
    let onSave: (String) -> Void
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void

    @State private var text: String = ""
    @FocusState private var isNoteFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(annotation.text)
                .font(.callout)
                .italic()
                .lineLimit(4)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 8) {
                ForEach(HighlightColor.allCases, id: \.self) { color in
                    Button { onChangeColor(color) } label: {
                        Circle()
                            .fill(color == .underline ? Color.clear : color.swiftUIColor)
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().strokeBorder(
                                    annotation.color == color ? Color.accentColor : .black.opacity(0.15),
                                    lineWidth: annotation.color == color ? 2 : 1
                                )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                .focused($isNoteFocused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Add a note…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Button("Delete Highlight", role: .destructive) { onDelete() }
                Spacer()
                Button("Done") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            text = annotation.note ?? ""
            if autofocus {
                // Let the popover finish presenting before stealing focus.
                DispatchQueue.main.async { isNoteFocused = true }
            }
        }
    }
}

/// Sidebar listing every highlight and bookmark in the book.
struct AnnotationsInspector: View {
    let annotations: [Annotation]
    let bookmarks: [Bookmark]
    let onSelect: (Locator) -> Void
    let onEdit: (Annotation) -> Void
    let onDelete: (Annotation) -> Void

    var body: some View {
        Group {
            if annotations.isEmpty && bookmarks.isEmpty {
                ContentUnavailableView(
                    "No Notes Yet",
                    systemImage: "highlighter",
                    description: Text("Select text while reading to highlight it and add a note.")
                )
            } else {
                List {
                    if !bookmarks.isEmpty {
                        Section("Bookmarks") {
                            ForEach(bookmarks) { bookmark in
                                Button { onSelect(bookmark.locator) } label: {
                                    Label(
                                        bookmark.chapterTitle ?? "Bookmark",
                                        systemImage: "bookmark.fill"
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !annotations.isEmpty {
                        Section("Highlights") {
                            ForEach(sortedAnnotations) { annotation in
                                row(for: annotation)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Notes")
    }

    private var sortedAnnotations: [Annotation] {
        annotations.sorted {
            ($0.locator.spineIndex, $0.createdAt) < ($1.locator.spineIndex, $1.createdAt)
        }
    }

    private func row(for annotation: Annotation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { onSelect(annotation.locator) } label: {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(annotation.color.swiftUIColor)
                        .frame(width: 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(annotation.text)
                            .font(.callout)
                            .lineLimit(3)
                        if let note = annotation.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let chapter = annotation.chapterTitle {
                            Text(chapter)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                onEdit(annotation)
            } label: {
                Image(systemName: annotation.hasNote ? "note.text" : "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(annotation.hasNote ? "Edit note" : "Add note")
        }
        .contextMenu {
            Button(annotation.hasNote ? "Edit Note…" : "Add Note…") { onEdit(annotation) }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(annotation.text, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete(annotation) }
        }
    }
}

extension HighlightColor {
    var swiftUIColor: Color {
        switch self {
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.27)
        case .green: return Color(red: 0.49, green: 0.85, blue: 0.34)
        case .blue: return Color(red: 0.35, green: 0.67, blue: 0.98)
        case .pink: return Color(red: 1.0, green: 0.54, blue: 0.70)
        case .purple: return Color(red: 0.75, green: 0.56, blue: 0.98)
        case .underline: return Color(red: 0.90, green: 0.65, blue: 0.04)
        }
    }
}
