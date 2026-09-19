import AppKit
import EpubKit
import ReaderUI
import SwiftUI

/// The reading surface: page content, chrome over the page, and the notes inspector.
struct ReaderScreen: View {
    let book: ReaderDocument
    let reader: ReaderController

    @Environment(AppModel.self) private var model
    @State private var isShowingTypography = false
    @State private var editingAnnotation: Annotation?
    /// True when the note editor was opened from the selection palette's Add Note.
    @State private var noteEditorAutofocus = false
    /// True when the inspector was opened only to host the sidebar editor.
    @State private var inspectorOpenedForEditor = false
    @State private var isDrawingExpanded = false
    @State private var windowWidth: CGFloat = 0
    @AppStorage("reader.workspaceWidth") private var preferredWorkspaceWidth: Double = 340
    @AppStorage("reader.expandedWorkspaceWidth") private var preferredExpandedWorkspaceWidth: Double = 0
    @State private var isResizeHandleHovered = false
    @State private var dragStartWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity)
        }
        .padding(.trailing, model.workspace != .closed && !usesWorkspaceOverlay ? workspaceWidth : 0)
        .overlay(alignment: .trailing) {
            if model.workspace != .closed {
                workspacePanel
                    .frame(width: activeWorkspaceWidth)
                    .shadow(color: .black.opacity(usesWorkspaceOverlay ? 0.12 : 0), radius: 16, x: -6)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.workspace)
            .toolbar { toolbarContent }
            .task { model.startReading() }
            .onAppear {
                reader.onHighlightActivated = handleHighlightActivated
                model.resumeReadingAfterBrowser()
            }
            .sheet(item: sheetAnnotation) { annotation in
                // Re-read from the model so color/status updates while the sheet is open.
                NoteSheet(
                    annotation: model.annotation(with: annotation.id) ?? annotation,
                    autofocus: noteEditorAutofocus,
                    isDark: model.settings.theme.isDark,
                    onSave: { note, completion in
                        model.updateNote(note, for: annotation.id, completion: completion)
                    },
                    onChangeColor: { model.changeColor($0, for: annotation.id) },
                    onDelete: { deleteAnnotation(annotation.id) },
                    onAskAI: { askAIAbout(annotation) },
                    onTogglePlacement: { toggleNoteEditorPlacement() }
                )
            }
            .onChange(of: model.settings.noteEditorPlacement) { _, placement in
                handlePlacementChange(placement)
            }
            .onChange(of: model.isShowingAskAI) { _, _ in
                // Backup if a caller toggled visibility without pinning first.
                reader.pinRestoreCurrentPositionOnce()
            }
            .onChange(of: model.isShowingAnnotations) { _, showing in
                reader.pinRestoreCurrentPositionOnce()
                if !showing, model.workspace == .closed, model.settings.noteEditorPlacement == .sidebar {
                    editingAnnotation = nil
                    model.aiNoteTarget = nil
                    inspectorOpenedForEditor = false
                    isDrawingExpanded = false
                    reader.pinRestore(to: nil)
                }
            }
            .onChange(of: windowWidth) { _, _ in reader.pinRestoreCurrentPositionOnce() }
            .onDisappear {
                model.isNoteEditorOpen = false
                model.aiNoteTarget = nil
            }
            .background {
                WindowWidthReader { windowWidth = $0 }
            }
    }

    private var usesWorkspaceOverlay: Bool { windowWidth < 900 || (model.workspace == .notes && isDrawingExpanded) }

    private var maximumWorkspaceWidth: CGFloat {
        let width = windowWidth > 0 ? windowWidth : 1200
        // Keep room for the book, or a visible strip beside an overlay.
        return max(300, min(800, width - (windowWidth < 900 ? 56 : 400)))
    }

    private var workspaceWidth: CGFloat {
        min(maximumWorkspaceWidth, max(300, CGFloat(preferredWorkspaceWidth)))
    }

    private var activeWorkspaceWidth: CGFloat {
        model.workspace == .notes && isDrawingExpanded ? expandedWorkspaceWidth : workspaceWidth
    }

    private func resizeWorkspace(to width: CGFloat) {
        if model.workspace == .notes && isDrawingExpanded {
            preferredExpandedWorkspaceWidth = Double(min(maximumExpandedWorkspaceWidth, max(minimumExpandedWorkspaceWidth, width)))
        } else {
            preferredWorkspaceWidth = Double(min(maximumWorkspaceWidth, max(300, width)))
        }
    }

    private var maximumExpandedWorkspaceWidth: CGFloat {
        let width = windowWidth > 0 ? windowWidth : 1200
        return min(width, max(340, width - 56))
    }

    private var minimumExpandedWorkspaceWidth: CGFloat {
        min(340, maximumExpandedWorkspaceWidth)
    }

    private var expandedWorkspaceWidth: CGFloat {
        let width = windowWidth > 0 ? windowWidth : 1200
        let defaultWidth = min(maximumExpandedWorkspaceWidth, max(minimumExpandedWorkspaceWidth, width * 0.5))
        let preferredWidth = preferredExpandedWorkspaceWidth > 0 ? CGFloat(preferredExpandedWorkspaceWidth) : defaultWidth
        return min(maximumExpandedWorkspaceWidth, max(minimumExpandedWorkspaceWidth, preferredWidth))
    }

    private var workspacePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach([AppModel.Workspace.notes, .askAI], id: \.rawValue) { tab in
                    Button { selectWorkspace(tab) } label: {
                        Label(tab == .notes ? "Notes" : "Ask AI", systemImage: tab == .notes ? "note.text" : "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.workspace == tab ? model.settings.theme.accent : model.settings.theme.muted)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                if model.workspace == tab {
                                    Rectangle().fill(model.settings.theme.accent).frame(height: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .accessibilityLabel(tab == .notes ? "Notes" : "Ask AI")
                    .accessibilityAddTraits(model.workspace == tab ? .isSelected : [])
                }
                if model.workspace == .notes && isDrawingExpanded {
                    Button { isDrawingExpanded = false } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Collapse drawing workspace")
                }
                Button { closeWorkspace() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close workspace")
                .accessibilityLabel("Close workspace")
            }
            .padding(.horizontal, 16)
            Divider()
            ZStack {
                inspectorContent
                    .opacity(model.workspace == .notes ? 1 : 0)
                    .allowsHitTesting(model.workspace == .notes)
                    .accessibilityHidden(model.workspace != .notes)
                AskAIPanel()
                    .opacity(model.workspace == .askAI ? 1 : 0)
                    .allowsHitTesting(model.workspace == .askAI)
                    .accessibilityHidden(model.workspace != .askAI)
            }
        }
        .background(model.settings.theme.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(model.settings.theme.border).frame(width: 1)
        }
        .overlay(alignment: .leading) {
            SidebarResizeHandle(
                onBegin: {
                    dragStartWidth = activeWorkspaceWidth
                    reader.pinRestoreCurrentPositionOnce()
                },
                onDrag: { translation in
                    resizeWorkspace(to: (dragStartWidth ?? activeWorkspaceWidth) - translation)
                },
                onEnd: { dragStartWidth = nil }
            )
                .frame(width: 14)
                .overlay {
                    Capsule()
                        .fill(model.settings.theme.accent.opacity(isResizeHandleHovered || dragStartWidth != nil ? 0.7 : 0.25))
                        .frame(width: 3, height: 36)
                        .allowsHitTesting(false)
                }
                .onHover { isResizeHandleHovered = $0 }
                .help("Drag to resize the sidebar")
                .accessibilityLabel("Sidebar width")
                .accessibilityValue("\(Int(activeWorkspaceWidth)) points")
                .accessibilityHint("Drag left or right to resize the sidebar")
                .accessibilityAdjustableAction { direction in
                    reader.pinRestoreCurrentPositionOnce()
                    switch direction {
                    case .increment: resizeWorkspace(to: activeWorkspaceWidth + 20)
                    case .decrement: resizeWorkspace(to: activeWorkspaceWidth - 20)
                    @unknown default: break
                    }
                }
        }
    }

    private var chapterTitles: [String] {
        let titles = (model.record?.annotations ?? [])
            .compactMap(\.chapterTitle)
            .filter { !$0.isEmpty }
        return Array(Set(titles)).sorted()
    }

    // MARK: - Page

    private static let navRailWidth: CGFloat = 32
    /// Gap between each nav rail and the reading surface.
    private static let navContentGap: CGFloat = 0
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
                    readerSurface
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .readerKeyboardShortcuts(
                            reader,
                            spaceAction: reader.nextPage,
                            onSuppressChange: { model.isNoteEditorOpen = $0 }
                        )
                        .overlay(alignment: .topLeading) { selectionPopover }

                    ProgressFooter(reader: reader)
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

    @ViewBuilder
    private var readerSurface: some View {
        switch book {
        case .epub(let epub):
            ReaderWebView(controller: reader, book: epub)
        case .pdf(let pdf):
            ReaderPDFView(controller: reader, book: pdf)
        }
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
                    addNote(from: selection)
                },
                onAskAI: {
                    editingAnnotation = nil
                    model.addSelectionToChat()
                },
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

    /// Modal sheet is presented (as opposed to the sidebar inspector).
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
                if newValue == nil, model.workspace != .askAI {
                    model.aiNoteTarget = nil
                }
            }
        )
    }

    @ViewBuilder
    private var inspectorContent: some View {
        Group {
            if isSidebarPlacement, let annotation = editingAnnotation {
                Color.clear
                    .overlay {
                        NoteEditor(
                            annotation: model.annotation(with: annotation.id) ?? annotation,
                            autofocus: noteEditorAutofocus,
                            presentation: .sidebar,
                            drawingScene: model.drawingScene(for: annotation.id),
                            isDark: model.settings.theme.isDark,
                            onSave: { note, completion in
                                model.updateNote(note, for: annotation.id, completion: completion)
                            },
                            onSaveDrawing: { scene, elementCount, completion in
                                model.updateDrawing(
                                    scene: scene,
                                    elementCount: elementCount,
                                    for: annotation.id,
                                    completion: completion
                                )
                            },
                            onChangeColor: { model.changeColor($0, for: annotation.id) },
                            onDelete: { deleteAnnotation(annotation.id) },
                            onClose: { finishEditing() },
                            onAskAI: { askAIAbout(annotation) },
                            onBack: { backToNotesList() },
                            onTogglePlacement: { toggleNoteEditorPlacement() },
                            onDrawActiveChanged: { active in
                                setDrawingExpanded(active, annotation: annotation)
                            }
                        )
                        .id(annotation.id)
                    }
            } else {
                Color.clear
                    .overlay {
                        AnnotationsInspector(
                            annotations: model.record?.annotations ?? [],
                            bookmarks: model.record?.bookmarks ?? [],
                            chapterTitles: chapterTitles,
                            onSelect: { reader.go(to: $0) },
                            onEdit: { openNoteEditor($0, autofocus: !$0.hasContent) },
                            onDelete: { deleteAnnotation($0.id) },
                            onExport: {
                                NotesExporter.presentSavePanel(
                                    bookTitle: book.title,
                                    markdown: model.exportNotesMarkdown()
                                )
                            }
                        )
                    }
            }
        }
        .background(model.settings.theme.surface)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isDrawingExpanded)
    }

    private var inspectorWidths: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        guard isDrawingExpanded else { return (280, 360, 600) }
        let width = windowWidth > 0 ? windowWidth : 1200
        let maxWidth = max(360, width - 240)
        let minWidth = min(maxWidth, max(width * 0.5, 480))
        let ideal = min(maxWidth, max(width * 0.75, minWidth))
        return (minWidth, ideal, maxWidth)
    }

    private func handleHighlightActivated(id: UUID, rect: CGRect) {
        guard let annotation = model.annotation(with: id) else { return }
        openNoteEditor(annotation, autofocus: !annotation.hasContent)
    }

    private func addNote(from selection: ReaderSelection) {
        reader.pinRestoreOnce(to: selection.locator.start)
        guard let created = model.addHighlight(color: model.nextColorForNewNote()) else { return }
        DispatchQueue.main.async {
            openNoteEditor(created, autofocus: true)
        }
    }

    private func openNoteEditor(_ annotation: Annotation, autofocus: Bool) {
        noteEditorAutofocus = autofocus
        model.aiNoteTarget = .annotation(annotation.id)
        editingAnnotation = annotation
        if isSidebarPlacement, !model.isShowingAnnotations {
            reader.pinRestoreOnce(to: annotation.locator.start)
            inspectorOpenedForEditor = true
            model.isShowingAnnotations = true
        }
    }

    private func finishEditing() {
        editingAnnotation = nil
        model.aiNoteTarget = nil
        isDrawingExpanded = false
        reader.pinRestore(to: nil)
        if inspectorOpenedForEditor {
            model.isShowingAnnotations = false
            inspectorOpenedForEditor = false
        }
    }

    private func backToNotesList() {
        editingAnnotation = nil
        model.aiNoteTarget = nil
        inspectorOpenedForEditor = false
        isDrawingExpanded = false
        reader.pinRestore(to: nil)
        model.isShowingAnnotations = true
    }

    private func askAIAbout(_ annotation: Annotation) {
        model.addAnnotationToChat(model.annotation(with: annotation.id) ?? annotation)
        if !isSidebarPlacement {
            // The highlight remains active while the modal editor gets out of
            // the way of the shared Ask AI workspace.
            editingAnnotation = nil
        }
    }

    private func deleteAnnotation(_ id: UUID) {
        let deletingActiveTarget: Bool
        if case .annotation(id) = model.aiNoteTarget {
            deletingActiveTarget = true
        } else {
            deletingActiveTarget = false
        }
        model.deleteAnnotation(id)
        if deletingActiveTarget {
            editingAnnotation = nil
            isDrawingExpanded = false
        }
    }

    private func selectWorkspace(_ workspace: AppModel.Workspace) {
        model.workspace = workspace
        if workspace == .notes,
           editingAnnotation == nil,
           case .annotation(let id) = model.aiNoteTarget,
           let annotation = model.annotation(with: id)
        {
            noteEditorAutofocus = false
            editingAnnotation = annotation
        }
    }

    private func closeWorkspace() {
        model.workspace = .closed
        editingAnnotation = nil
        model.aiNoteTarget = nil
        inspectorOpenedForEditor = false
        isDrawingExpanded = false
        reader.pinRestore(to: nil)
    }

    private func setDrawingExpanded(_ active: Bool, annotation: Annotation) {
        withAnimation(.easeInOut(duration: 0.22)) {
            isDrawingExpanded = active
        }
        if active, !annotation.isOrphaned {
            reader.pinRestore(to: annotation.locator.start)
            reader.go(to: annotation.locator)
        } else {
            reader.pinRestore(to: nil)
        }
    }

    private func toggleNoteEditorPlacement() {
        model.settings.noteEditorPlacement =
            isSidebarPlacement ? .sheet : .sidebar
    }

    private func handlePlacementChange(_ placement: NoteEditorPlacement) {
        guard editingAnnotation != nil else { return }
        if placement == .sidebar {
            if !model.isShowingAnnotations {
                inspectorOpenedForEditor = true
                model.isShowingAnnotations = true
            }
        } else if inspectorOpenedForEditor {
            model.isShowingAnnotations = false
            inspectorOpenedForEditor = false
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goHome() } label: {
                Label("Home", systemImage: "house")
            }
            .quickHelp("Home")

            Button { model.toggleAskAI() } label: {
                Label("Ask AI", systemImage: "sparkles")
            }
            .quickHelp(model.isShowingAskAI ? "Hide Ask AI" : "Ask AI")
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(book.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let chapter = reader.chapterTitle, chapter != book.title {
                    Text(chapter)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
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
                if reader.isPDF {
                    PDFAppearancePopover(reader: reader)
                } else {
                    TypographyPopover()
                }
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
                TableOfContentsView(document: book, reader: reader) {
                    model.isShowingContents = false
                }
                .frame(width: 320, height: 480)
            }

            Button { model.toggleAnnotations() } label: {
                Label("Notes", systemImage: "list.bullet.rectangle")
            }
            .quickHelp("Notes and highlights")
        }
    }
}

/// Reads the host window width so inspector expansion is not tied to the reading pane.
private struct WindowWidthReader: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.onChange = onChange
        (nsView as? TrackingView)?.publish()
    }

    private final class TrackingView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var lastWidth: CGFloat = 0
        private var resizeToken: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resizeToken {
                NotificationCenter.default.removeObserver(resizeToken)
                self.resizeToken = nil
            }
            if let window {
                resizeToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.publish()
                }
            }
            publish()
        }

        deinit {
            if let resizeToken {
                NotificationCenter.default.removeObserver(resizeToken)
            }
        }

        func publish() {
            guard let width = window?.frame.width, abs(width - lastWidth) > 0.5 else { return }
            lastWidth = width
            DispatchQueue.main.async { [onChange] in
                onChange?(width)
            }
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(isHovered ? 0.9 : 0.55))
                .frame(width: 28, height: 36)
                .background(
                    Circle()
                        .fill(.primary.opacity(isHovered ? 0.09 : 0.025))
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
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider() }
        .allowsHitTesting(false)
    }

    private var pageLabel: String {
        if reader.isPDF {
            let range = reader.visiblePageRange
            return range.lowerBound == range.upperBound
                ? "\(range.lowerBound + 1) of \(max(1, reader.pageCount))"
                : "\(range.lowerBound + 1)–\(range.upperBound + 1) of \(max(1, reader.pageCount))"
        }
        let current = max(1, reader.page + 1)
        let total = max(1, reader.pageCount)
        return "\(current) of \(total)"
    }

    private var pagesRemaining: String {
        if reader.isPDF {
            let left = max(0, reader.pageCount - reader.visiblePageRange.upperBound - 1)
            switch left {
            case 0: return "Last page"
            case 1: return "1 page left"
            default: return "\(left) pages left"
            }
        }
        let left = max(0, reader.pageCount - reader.page - 1)
        switch left {
        case 0: return "Last page in chapter"
        case 1: return "1 page left in chapter"
        default: return "\(left) pages left in chapter"
        }
    }
}

private struct PDFAppearancePopover: View {
    let reader: ReaderController
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("PDF appearance").font(.headline)
            HStack {
                Button("Zoom Out") { reader.zoomPDFOut() }
                Button("Fit Page") { reader.fitPDFPage() }
                Button("Zoom In") { reader.zoomPDFIn() }
            }
            Toggle("Two-page spread", isOn: $model.settings.twoPageSpread)
            Picker("Theme", selection: $model.settings.theme) {
                ForEach(ReaderTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            Text("Theme changes the reader chrome; PDF page colors are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 340)
    }
}

/// A native divider keeps mouse tracking stable while SwiftUI and the web
/// reader relayout on either side of the pointer.
private struct SidebarResizeHandle: NSViewRepresentable {
    var onBegin: () -> Void
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onBegin: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var trackingArea: NSTrackingArea?
        private var isInside = false
        private var startX: CGFloat?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            isInside = true
            NSCursor.resizeLeftRight.set()
        }

        override func mouseMoved(with event: NSEvent) {
            guard isInside else { return }
            NSCursor.resizeLeftRight.set()
        }

        override func mouseExited(with event: NSEvent) {
            isInside = false
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { isInside = false }
            window?.invalidateCursorRects(for: self)
        }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            onBegin?()
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            onDrag?(event.locationInWindow.x - startX)
            NSCursor.resizeLeftRight.set()
        }

        override func mouseUp(with event: NSEvent) {
            if let startX { onDrag?(event.locationInWindow.x - startX) }
            startX = nil
            onEnd?()
        }
    }
}
