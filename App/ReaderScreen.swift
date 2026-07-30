import EpubKit
import ReaderUI
import SwiftUI

/// The reading surface: page content, a table of contents sidebar, the
/// annotations inspector, and the chrome that appears over the page.
struct ReaderScreen: View {
    let book: EPUBBook
    let reader: ReaderController

    @Environment(AppModel.self) private var model
    @State private var isShowingTypography = false
    @State private var editingAnnotation: Annotation?
    /// True when the note editor was opened from the selection palette's Add Note.
    @State private var noteEditorAutofocus = false
    @State private var chromeVisible = true

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            TableOfContentsView(book: book, reader: reader)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            page
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $model.isShowingAnnotations) {
            AnnotationsInspector(
                annotations: model.record?.annotations ?? [],
                bookmarks: model.record?.bookmarks ?? [],
                onSelect: { reader.go(to: $0) },
                onEdit: { openNoteEditor($0, autofocus: !$0.hasNote) },
                onDelete: { model.deleteAnnotation($0.id) }
            )
            .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        .toolbar { toolbarContent }
        .task { model.startReading() }
        .onAppear { reader.onHighlightActivated = handleHighlightActivated }
    }

    // MARK: - Page

    private var page: some View {
        ZStack(alignment: .bottom) {
            ReaderWebView(controller: reader, book: book)
                .background(model.settings.theme.uiBackground)
                .readerKeyboardShortcuts(reader)

            if chromeVisible {
                ProgressFooter(reader: reader)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if reader.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.thinMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .overlay(alignment: .topLeading) { selectionPopover }
        .animation(.easeInOut(duration: 0.18), value: chromeVisible)
        .animation(.easeInOut(duration: 0.18), value: reader.isLoading)
        .popover(item: $editingAnnotation) { annotation in
            NoteEditor(
                annotation: annotation,
                autofocus: noteEditorAutofocus,
                onSave: { model.updateNote($0, for: annotation.id) },
                onChangeColor: { model.changeColor($0, for: annotation.id) },
                onDelete: {
                    model.deleteAnnotation(annotation.id)
                    editingAnnotation = nil
                }
            )
        }
    }

    /// Anchored to the selection's own rect, which the runtime reports in
    /// viewport coordinates.
    @ViewBuilder
    private var selectionPopover: some View {
        if let selection = reader.selection {
            HighlightPalette(
                onPick: { _ = model.addHighlight(color: $0) },
                onAddNote: {
                    // Yellow is the default highlight colour when noting in one step.
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
                    .font(.headline)
                    .lineLimit(1)
                if let chapter = reader.chapterTitle {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .help("Bookmark this page")

            Button { isShowingTypography.toggle() } label: {
                Label("Appearance", systemImage: "textformat.size")
            }
            .help("Text and appearance")
            .popover(isPresented: $isShowingTypography, arrowEdge: .bottom) {
                TypographyPopover()
            }

            Button { model.isShowingAnnotations.toggle() } label: {
                Label("Notes", systemImage: "list.bullet.rectangle")
            }
            .help("Notes and highlights")
        }
    }
}

/// Progress through the book, with a scrubber and pages left in the chapter.
private struct ProgressFooter: View {
    let reader: ReaderController
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? reader.progress },
                    set: { scrubbing = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        reader.seek(toProgress: target)
                        scrubbing = nil
                    }
                }
            )
            .controlSize(.small)

            HStack {
                Text("\(Int((scrubbing ?? reader.progress) * 100))%")
                Spacer()
                Text(pagesRemaining)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
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
