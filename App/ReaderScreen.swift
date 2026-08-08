import EpubKit
import ReaderUI
import SwiftUI

/// The reading surface: page content, chrome over the page, and the notes inspector.
struct ReaderScreen: View {
    let book: EPUBBook
    let reader: ReaderController

    @Environment(AppModel.self) private var model
    @State private var isShowingTypography = false
    @State private var editingAnnotation: Annotation?
    /// True when the note editor was opened from the selection palette's Add Note.
    @State private var noteEditorAutofocus = false

    var body: some View {
        @Bindable var model = model

        page
            .inspector(isPresented: $model.isShowingAnnotations) {
                AnnotationsInspector(
                    annotations: model.record?.annotations ?? [],
                    bookmarks: model.record?.bookmarks ?? [],
                    chapterTitles: chapterTitles,
                    onSelect: { reader.go(to: $0) },
                    onEdit: { openNoteEditor($0, autofocus: !$0.hasNote) },
                    onDelete: { model.deleteAnnotation($0.id) },
                    onExport: {
                        NotesExporter.presentSavePanel(
                            bookTitle: book.title,
                            markdown: model.exportNotesMarkdown()
                        )
                    }
                )
                .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
            }
            .toolbar { toolbarContent }
            .task { model.startReading() }
            .onAppear { reader.onHighlightActivated = handleHighlightActivated }
            .sheet(item: $editingAnnotation) { annotation in
                // Re-read from the model so color/status updates while the sheet is open.
                NoteSheet(
                    annotation: model.annotation(with: annotation.id) ?? annotation,
                    autofocus: noteEditorAutofocus,
                    onSave: { model.updateNote($0, for: annotation.id) },
                    onChangeColor: { model.changeColor($0, for: annotation.id) },
                    onDelete: {
                        model.deleteAnnotation(annotation.id)
                        editingAnnotation = nil
                    }
                )
            }
            .onChange(of: editingAnnotation) { _, annotation in
                model.isNoteEditorOpen = annotation != nil
            }
            .onDisappear {
                model.isNoteEditorOpen = false
            }
    }

    private var chapterTitles: [String] {
        let titles = (model.record?.annotations ?? [])
            .compactMap(\.chapterTitle)
            .filter { !$0.isEmpty }
        return Array(Set(titles)).sorted()
    }

    // MARK: - Page

    private static let navRailWidth: CGFloat = 60
    /// Gap between each nav rail and the reading surface.
    private static let navContentGap: CGFloat = 12

    private var page: some View {
        ZStack {
            HStack(spacing: Self.navContentGap) {
                navRail(systemImage: "chevron.left") {
                    reader.previousPage()
                }

                ReaderWebView(controller: reader, book: book)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .readerKeyboardShortcuts(reader, enabled: editingAnnotation == nil)
                    .overlay(alignment: .topLeading) { selectionPopover }

                navRail(systemImage: "chevron.right") {
                    reader.nextPage()
                }
            }
            .background(model.settings.theme.uiBackground)

            VStack {
                Spacer()
                ProgressFooter(reader: reader)
                    .padding(.horizontal, Self.navRailWidth + Self.navContentGap)
            }

            if reader.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.thinMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: reader.isLoading)
    }

    /// Dedicated side column for a page-turn control — never overlaps text.
    private func navRail(systemImage: String, action: @escaping () -> Void) -> some View {
        VStack {
            Spacer()
            PageTurnButton(systemImage: systemImage, action: action)
            Spacer()
        }
        .frame(width: Self.navRailWidth)
    }

    /// Anchored to the selection's own rect, which the runtime reports in
    /// viewport coordinates.
    @ViewBuilder
    private var selectionPopover: some View {
        if let selection = reader.selection {
            HighlightPalette(
                onPick: { _ = model.addHighlight(color: $0) },
                onAddNote: {
                    if let created = model.addHighlight(color: .yellow) {
                        openNoteEditor(created, autofocus: true)
                    }
                },
                onDismiss: { reader.clearSelection() }
            )
            .offset(
                x: max(12, selection.rect.midX - 160),
                y: max(12, selection.rect.maxY + 10)
            )
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    private func handleHighlightActivated(id: UUID, rect: CGRect) {
        guard let annotation = model.annotation(with: id) else { return }
        openNoteEditor(annotation, autofocus: !annotation.hasNote)
    }

    private func openNoteEditor(_ annotation: Annotation, autofocus: Bool) {
        noteEditorAutofocus = autofocus
        editingAnnotation = annotation
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(book.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let chapter = reader.chapterTitle {
                    Text(chapter)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.toggleBookmark()
            } label: {
                Label(
                    "Bookmark",
                    systemImage: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark"
                )
            }
            .quickHelp("Bookmark this page")

            Button { isShowingTypography.toggle() } label: {
                Label("Appearance", systemImage: "textformat.size")
            }
            .quickHelp("Text and appearance")
            .popover(isPresented: $isShowingTypography, arrowEdge: .bottom) {
                TypographyPopover()
            }

            Button { model.isShowingContents.toggle() } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            .quickHelp("Table of contents")
            .popover(
                isPresented: Binding(
                    get: { model.isShowingContents },
                    set: { model.isShowingContents = $0 }
                ),
                arrowEdge: .bottom
            ) {
                TableOfContentsView(book: book, reader: reader) {
                    model.isShowingContents = false
                }
                .frame(width: 320, height: 480)
            }

            Button { model.isShowingAnnotations.toggle() } label: {
                Label("Notes", systemImage: "list.bullet.rectangle")
            }
            .quickHelp("Notes and highlights")
        }
    }
}

/// Soft circular edge control, quiet at rest and clearer on hover.
private struct PageTurnButton: View {
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary.opacity(isHovered ? 0.9 : 0.55))
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(.primary.opacity(isHovered ? 0.14 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(systemImage.contains("left") ? "Previous page" : "Next page")
    }
}

/// Text-only progress chrome — no scrubber.
private struct ProgressFooter: View {
    let reader: ReaderController

    var body: some View {
        HStack {
            Color.clear.frame(width: 1, height: 1)
            Spacer(minLength: 0)
            Text(pageLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            Text(pagesRemaining)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 22)
        .padding(.top, 8)
        .allowsHitTesting(false)
    }

    private var pageLabel: String {
        let current = max(1, reader.page + 1)
        let total = max(1, reader.pageCount)
        return "\(current) of \(total)"
    }

    private var pagesRemaining: String {
        let left = max(0, reader.pageCount - reader.page - 1)
        switch left {
        case 0: return "Last page in chapter"
        case 1: return "1 page left in chapter"
        default: return "\(left) pages left in chapter"
        }
    }
}
