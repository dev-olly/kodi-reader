import AppKit
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
    /// True when the inspector was opened only to host the sidebar editor.
    @State private var inspectorOpenedForEditor = false
    @State private var noteEditorStartInDraw = false

    var body: some View {
        @Bindable var model = model

        page
            .inspector(isPresented: $model.isShowingAnnotations) {
                inspectorContent
            }
            .toolbar { toolbarContent }
            .task { model.startReading() }
            .onAppear { reader.onHighlightActivated = handleHighlightActivated }
            .sheet(item: sheetAnnotation) { annotation in
                // Re-read from the model so color/status updates while the sheet is open.
                NoteSheet(
                    annotation: model.annotation(with: annotation.id) ?? annotation,
                    autofocus: noteEditorAutofocus,
                    drawingScene: model.drawingScene(for: annotation.id),
                    isDark: model.settings.theme.isDark,
                    startInDraw: noteEditorStartInDraw,
                    onSave: { model.updateNote($0, for: annotation.id) },
                    onSaveDrawing: { model.updateDrawing(scene: $0, elementCount: $1, for: annotation.id) },
                    onChangeColor: { model.changeColor($0, for: annotation.id) },
                    onDelete: { model.deleteAnnotation(annotation.id) },
                    onTogglePlacement: { toggleNoteEditorPlacement() },
                    onRequestSheetForDraw: { noteEditorStartInDraw = true }
                )
            }
            .onChange(of: editingAnnotation) { _, _ in
                syncModalEditorFlag()
            }
            .onChange(of: model.settings.noteEditorPlacement) { _, placement in
                handlePlacementChange(placement)
            }
            .onChange(of: model.isShowingAnnotations) { _, showing in
                if !showing, model.settings.noteEditorPlacement == .sidebar {
                    editingAnnotation = nil
                    inspectorOpenedForEditor = false
                    syncModalEditorFlag()
                }
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
    /// Caps the web view so two-page columns stay readable on ultra-wide displays.
    private static let maxReadingWidth: CGFloat = 2000
    private static var maxReadingClusterWidth: CGFloat {
        maxReadingWidth + 2 * navRailWidth + 2 * navContentGap
    }

    private var page: some View {
        ZStack {
            HStack(spacing: Self.navContentGap) {
                navRail(systemImage: "chevron.left") {
                    reader.previousPage()
                }

                VStack(spacing: 0) {
                    ReaderWebView(controller: reader, book: book)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .readerKeyboardShortcuts(
                            reader,
                            enabled: !isModalNoteEditor,
                            spaceAction: {
                                if model.readAloud.isActive {
                                    model.readAloud.togglePause()
                                } else {
                                    reader.nextPage()
                                }
                            }
                        )
                        .overlay(alignment: .topLeading) { selectionPopover }

                    if model.readAloud.isActive {
                        ReadAloudBar()
                    } else {
                        ProgressFooter(reader: reader)
                    }
                }

                navRail(systemImage: "chevron.right") {
                    reader.nextPage()
                }
            }
            .frame(maxWidth: Self.maxReadingClusterWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.settings.theme.uiBackground)

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
                onPlay: { model.startReadAloudFromSelection() },
                onCopy: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selection.text, forType: .string)
                },
                onDismiss: { reader.clearSelection() }
            )
            .offset(
                x: max(12, selection.rect.midX - 200),
                y: max(12, selection.rect.maxY + 10)
            )
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    private var isSidebarPlacement: Bool {
        model.settings.noteEditorPlacement == .sidebar
    }

    /// Modal sheet is up — page-turn shortcuts should stay off.
    private var isModalNoteEditor: Bool {
        editingAnnotation != nil && !isSidebarPlacement
    }

    private var sheetAnnotation: Binding<Annotation?> {
        Binding(
            get: { isSidebarPlacement ? nil : editingAnnotation },
            set: { newValue in
                // Hiding the sheet because we docked it must not clear the editor.
                if isSidebarPlacement, newValue == nil { return }
                editingAnnotation = newValue
            }
        )
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if isSidebarPlacement, let annotation = editingAnnotation {
            NoteEditor(
                annotation: model.annotation(with: annotation.id) ?? annotation,
                autofocus: noteEditorAutofocus,
                presentation: .sidebar,
                onSave: { model.updateNote($0, for: annotation.id) },
                onChangeColor: { model.changeColor($0, for: annotation.id) },
                onDelete: { model.deleteAnnotation(annotation.id) },
                onClose: { finishEditing() },
                onBack: { backToNotesList() },
                onTogglePlacement: { toggleNoteEditorPlacement() }
            )
            .id(annotation.id)
            .inspectorColumnWidth(min: 280, ideal: 380, max: 480)
        } else {
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
    }

    private func handleHighlightActivated(id: UUID, rect: CGRect) {
        guard let annotation = model.annotation(with: id) else { return }
        openNoteEditor(annotation, autofocus: !annotation.hasNote)
    }

    private func openNoteEditor(_ annotation: Annotation, autofocus: Bool) {
        noteEditorAutofocus = autofocus
        if isSidebarPlacement, !model.isShowingAnnotations {
            inspectorOpenedForEditor = true
            model.isShowingAnnotations = true
        }
        editingAnnotation = annotation
        syncModalEditorFlag()
    }

    private func finishEditing() {
        editingAnnotation = nil
        if inspectorOpenedForEditor {
            model.isShowingAnnotations = false
            inspectorOpenedForEditor = false
        }
        syncModalEditorFlag()
    }

    private func backToNotesList() {
        editingAnnotation = nil
        inspectorOpenedForEditor = false
        model.isShowingAnnotations = true
        syncModalEditorFlag()
    }

    private func toggleNoteEditorPlacement() {
        model.settings.noteEditorPlacement =
            isSidebarPlacement ? .sheet : .sidebar
    }

    private func handlePlacementChange(_ placement: NoteEditorPlacement) {
        if editingAnnotation == nil {
            syncModalEditorFlag()
            return
        }
        if placement == .sidebar {
            if !model.isShowingAnnotations {
                inspectorOpenedForEditor = true
                model.isShowingAnnotations = true
            }
        } else if inspectorOpenedForEditor {
            model.isShowingAnnotations = false
            inspectorOpenedForEditor = false
        }
        syncModalEditorFlag()
    }

    private func syncModalEditorFlag() {
        model.isNoteEditorOpen = isModalNoteEditor
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
                model.toggleReadAloud()
            } label: {
                Label(
                    "Read Aloud",
                    systemImage: model.readAloud.isPlaying
                        ? "speaker.wave.2.fill"
                        : "speaker.wave.2"
                )
            }
            .quickHelp(model.readAloud.isActive ? "Stop reading" : "Read aloud")

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
