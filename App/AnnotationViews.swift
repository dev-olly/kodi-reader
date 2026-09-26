import AppKit
import EpubKit
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

/// Colour picker shown next to a fresh selection, plus a way to open a note.
struct HighlightPalette: View {
    let onPick: (HighlightColor) -> Void
    let onAddNote: () -> Void
    let onAskAI: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    @State private var copied = false
    @State private var copyGeneration = 0

    var body: some View {
        PointerCursorContainer {
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
                    HStack(spacing: 4) {
                        Image(systemName: "text.badge.plus")
                        Text("Note")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Highlight and add a note")

                Button(action: onAskAI) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Ask AI")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Ask AI about this selection")

                Button(action: copyTapped) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? Color.secondary : Color.primary)
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied to clipboard" : "Copy selected text")
                .overlay(alignment: .bottom) {
                    if copied {
                        Text("Copied to clipboard")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: .rect(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            .fixedSize()
                            .offset(y: 22)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .allowsHitTesting(false)
                    }
                }

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
            .padding(.bottom, copied ? 26 : 0)
            .animation(.easeInOut(duration: 0.15), value: copied)
        }
        .shadow(radius: 8, y: 3)
    }

    private func copyTapped() {
        onCopy()
        withAnimation(.easeInOut(duration: 0.15)) {
            copied = true
        }
        copyGeneration += 1
        let generation = copyGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if generation == copyGeneration {
                withAnimation(.easeInOut(duration: 0.15)) {
                    copied = false
                }
            }
        }
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

/// Hosts the palette in AppKit so a pointing-hand cursor wins over WKWebView’s I-beam.
private struct PointerCursorContainer<Content: View>: NSViewRepresentable {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> PointerCursorHost {
        let host = PointerCursorHost()
        host.clipsToBounds = false
        let hosting = PointerCursorHostingView(rootView: content)
        hosting.clipsToBounds = false
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

    func updateNSView(_ nsView: PointerCursorHost, context: Context) {
        context.coordinator.hosting?.rootView = content
        nsView.invalidateIntrinsicContentSize()
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var hosting: PointerCursorHostingView<Content>?
    }
}

/// Skips `super.resetCursorRects()` so descendant `Text` views cannot install an I-beam.
private final class PointerCursorHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class PointerCursorHost: NSView {
    private var trackingArea: NSTrackingArea?
    private var isInside = false

    override var acceptsFirstResponder: Bool { false }

    override var intrinsicContentSize: NSSize {
        guard let hosting = subviews.first else { return .zero }
        return hosting.fittingSize
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        NSCursor.pointingHand.set()
    }

    // WKWebView underneath resets the I-beam on every move, so reassert the
    // pointing hand each time while the pointer is over the bar.
    override func mouseMoved(with event: NSEvent) {
        guard isInside else { return }
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isInside = false }
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
    @Environment(AppModel.self) private var model
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

    private var isEmpty: Bool { annotations.isEmpty && bookmarks.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmpty {
                emptyState
            } else {
                libraryHeader
                controls
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !bookmarks.isEmpty && query.isEmpty && filter == .all && chapterFilter.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                marginLabel("BOOKMARKS")
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

                        LazyVStack(alignment: .leading, spacing: 24) {
                            marginLabel("A THOUGHT TO KEEP")
                            if filteredAnnotations.isEmpty {
                                Text("No matches")
                                    .foregroundStyle(model.settings.theme.muted)
                            } else {
                                ForEach(filteredAnnotations) { annotation in
                                    row(for: annotation)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(model.settings.theme.uiForeground)
        .background(model.settings.theme.surface)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "highlighter")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(model.settings.theme.accent)
                    .frame(width: 48, height: 48)
                    .background(model.settings.theme.accent.opacity(0.08), in: .rect(cornerRadius: 14))
                    .padding(.bottom, 22)

                Text("Keep a little of\nwhat you read.")
                    .font(.system(size: 25, weight: .regular, design: .serif))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)

                Text("Your highlights, notes, and bookmarks will collect here as you read.")
                    .font(.system(size: 13))
                    .foregroundStyle(model.settings.theme.muted)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)

                Rectangle()
                    .fill(model.settings.theme.border.opacity(0.7))
                    .frame(height: 1)
                    .padding(.vertical, 24)

                Text("START WITH A PASSAGE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(model.settings.theme.muted)
                    .padding(.bottom, 16)

                emptyStateHint("cursorarrow", title: "Select a few words", detail: "Drag across a passage in the book.")
                    .padding(.bottom, 18)
                emptyStateHint("square.and.pencil", title: "Make it yours", detail: "Choose a highlight color or add a note.")
            }
            .frame(maxWidth: 300, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 28)
        }
    }

    private func emptyStateHint(_ icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(model.settings.theme.accent)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(model.settings.theme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your collection")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(model.settings.theme.muted)
                Text("\(annotations.count) \(annotations.count == 1 ? "highlight" : "highlights") · \(bookmarks.count) \(bookmarks.count == 1 ? "bookmark" : "bookmarks")")
                    .font(.system(size: 11))
                    .foregroundStyle(model.settings.theme.muted)
            }
            Spacer(minLength: 8)
            if annotations.contains(where: \.hasContent) {
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.settings.theme.muted)
                .accessibilityLabel("Export notes")
                .quickHelp("Export notes as Markdown")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private func marginLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .medium))
            .tracking(1)
            .foregroundStyle(model.settings.theme.muted)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(model.settings.theme.muted)
                TextField("Search your margin", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityLabel("Search notes")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(model.settings.theme.border.opacity(0.6)).frame(height: 1)
            }

            HStack(spacing: 16) {
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(NotesFilter.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(filter == .all ? "All entries" : filter.label)
                        .lineLimit(1)
                }
                .accessibilityLabel("Filter notes and highlights")
                if !chapterTitles.isEmpty {
                    Menu {
                        Picker("Chapter", selection: $chapterFilter) {
                            Text("All chapters").tag("")
                            ForEach(chapterTitles, id: \.self) { title in
                                Text(title).tag(title)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(chapterFilter.isEmpty ? "All chapters" : chapterFilter)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .accessibilityLabel("Filter by chapter")
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11))
            .foregroundStyle(model.settings.theme.muted)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 8)
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
                    if !annotation.hasContent { return false }
                case .highlightsOnly:
                    if annotation.hasContent { return false }
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
                        .frame(width: 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(annotation.title)
                                .font(.system(size: 16, design: .serif))
                                .lineSpacing(4)
                                .lineLimit(3)
                            if annotation.isOrphaned {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("Quote not found in chapter")
                            }
                            if annotation.hasDrawing {
                                Image(systemName: "scribble")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("Visual note")
                            }
                        }
                        if annotation.hasNote {
                            Text(annotation.plainNotePreview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else if annotation.hasDrawing {
                            Text("Visual note")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                Image(systemName: annotation.hasContent ? "note.text" : "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .quickHelp(annotation.hasContent ? "Edit note" : "Add note")
        }
        .contextMenu {
            Button(annotation.hasContent ? "Edit Note…" : "Add Note…") { onEdit(annotation) }
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
