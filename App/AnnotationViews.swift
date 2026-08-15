import AppKit
import EpubKit
import SwiftUI
import UniformTypeIdentifiers

/// Colour picker shown next to a fresh selection, plus a way to open a note.
struct HighlightPalette: View {
    let onPick: (HighlightColor) -> Void
    let onAddNote: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ArrowCursorContainer {
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
                    // Avoid Label/Text I-beam over the chip; keep a pointing arrow.
                    HStack(spacing: 4) {
                        Image(systemName: "text.badge.plus")
                        Text("Note")
                    }
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
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.arrow.set()
                case .ended:
                    break
                }
            }
        }
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

/// Hosts the palette in AppKit so cursor rects win over WKWebView’s I-beam.
private struct ArrowCursorContainer<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> ArrowCursorHost {
        let host = ArrowCursorHost()
        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        context.coordinator.hosting = hosting
        return host
    }

    func updateNSView(_ nsView: ArrowCursorHost, context: Context) {
        context.coordinator.hosting?.rootView = content()
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var hosting: NSHostingView<Content>?
    }
}

private final class ArrowCursorHost: NSView {
    override var acceptsFirstResponder: Bool { false }

    override var intrinsicContentSize: NSSize {
        guard let hosting = subviews.first else { return .zero }
        return hosting.fittingSize
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
        invalidateIntrinsicContentSize()
    }
}

private enum NotesFilter: String, CaseIterable, Identifiable {
    case all
    case withNotes
    case highlightsOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .withNotes: return "With notes"
        case .highlightsOnly: return "Highlights only"
        }
    }
}

/// Sidebar listing bookmarks and a searchable notes library for the open book.
struct AnnotationsInspector: View {
    let annotations: [Annotation]
    let bookmarks: [Bookmark]
    let chapterTitles: [String]
    let onSelect: (Locator) -> Void
    let onEdit: (Annotation) -> Void
    let onDelete: (Annotation) -> Void
    let onExport: () -> Void

    @State private var query = ""
    @State private var filter: NotesFilter = .all
    @State private var chapterFilter: String = ""

    var body: some View {
        Group {
            if annotations.isEmpty && bookmarks.isEmpty {
                ContentUnavailableView(
                    "No Notes Yet",
                    systemImage: "highlighter",
                    description: Text("Select text while reading to highlight it and add a note.")
                )
            } else {
                VStack(spacing: 0) {
                    controls
                    List {
                        if !bookmarks.isEmpty && query.isEmpty && filter == .all && chapterFilter.isEmpty {
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

                        Section("Notes") {
                            if filteredAnnotations.isEmpty {
                                Text("No matches")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(filteredAnnotations) { annotation in
                                    row(for: annotation)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onExport) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .quickHelp("Export notes as Markdown")
                .disabled(annotations.filter(\.hasNote).isEmpty)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search notes", text: $query)
                .textFieldStyle(.roundedBorder)

            Picker("Filter", selection: $filter) {
                ForEach(NotesFilter.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !chapterTitles.isEmpty {
                Picker("Chapter", selection: $chapterFilter) {
                    Text("All chapters").tag("")
                    ForEach(chapterTitles, id: \.self) { title in
                        Text(title).tag(title)
                    }
                }
                .labelsHidden()
            }
        }
        .padding(12)
    }

    private var filteredAnnotations: [Annotation] {
        annotations
            .sorted {
                ($0.locator.spineIndex, $0.createdAt) < ($1.locator.spineIndex, $1.createdAt)
            }
            .filter { annotation in
                switch filter {
                case .all: break
                case .withNotes:
                    if !annotation.hasNote { return false }
                case .highlightsOnly:
                    if annotation.hasNote { return false }
                }

                if !chapterFilter.isEmpty, annotation.chapterTitle != chapterFilter {
                    return false
                }

                guard !query.isEmpty else { return true }
                let haystack = [
                    annotation.text,
                    annotation.note ?? "",
                    annotation.chapterTitle ?? "",
                ].joined(separator: "\n")
                return haystack.localizedCaseInsensitiveContains(query)
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
                        HStack(spacing: 6) {
                            Text(annotation.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(3)
                            if annotation.isOrphaned {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("Quote not found in chapter")
                            }
                        }
                        if annotation.hasNote {
                            Text(annotation.plainNotePreview)
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
            .quickHelp(annotation.hasNote ? "Edit note" : "Add note")
        }
        .contextMenu {
            Button(annotation.hasNote ? "Edit Note…" : "Add Note…") { onEdit(annotation) }
            Button("Copy Quote") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(annotation.text, forType: .string)
            }
            if annotation.hasNote {
                Button("Copy Note") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(annotation.note ?? "", forType: .string)
                }
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

/// Presents a save panel and writes the book's notes as Markdown.
enum NotesExporter {
    static func presentSavePanel(bookTitle: String, markdown: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Notes — \(bookTitle).md"
        panel.message = "Export notes as Markdown"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}
