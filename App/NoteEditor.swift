import Foundation
import EpubKit
import ReaderUI
import SwiftUI

/// Shared note editor used as a modal sheet or the trailing inspector.
struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    enum Presentation {
        case sheet
        case sidebar
    }

    let annotation: Annotation
    var autofocus: Bool = false
    var presentation: Presentation = .sheet
    var isDark: Bool = false
    let onSave: (String, Bool, @escaping (Result<Void, Error>) -> Void) -> Void
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    var onAskAI: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var onTogglePlacement: (() -> Void)? = nil
    var onDrawActiveChanged: ((Bool) -> Void)? = nil

    @State private var text: String = ""
    @State private var selectedColor: HighlightColor = .yellow
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var mode: EditorMode = .edit
    @State private var saveWork: DispatchWorkItem?
    @State private var drawingWork: DispatchWorkItem?
    @State private var didLoad = false
    @State private var lastSavedText = ""
    @State private var saveRevision = 0
    @State private var sourceModeReason: String?
    @State private var saveStatus: SaveStatus = .saved
    @State private var drawingController = ExcalidrawController()
    @State private var activeSketch: NoteSketch?
    @State private var draftRange: NSRange?
    @State private var returnMode: EditorMode = .edit
    @State private var sceneDirty = false
    @State private var checkpointInFlight = false
    @State private var pendingCheckpoint = false
    @State private var shouldDiscardEmptyDraft = false
    @State private var canvasWaiters: [(Result<Void, Error>) -> Void] = []
    @State private var sceneRevision = 0
    @State private var editorSession = UUID()
    @State private var noteSession = UUID()
    @State private var previewRevision = 0
    @State private var didDelete = false
    @State private var errorMessage: String?

    private enum EditorMode {
        case edit
        case source
        case preview
        case draw
        case sketches
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

    private var theme: ReaderTheme {
        isDark ? .dark : .light
    }

    private var horizontalPadding: CGFloat {
        presentation == .sidebar ? 26 : 44
    }

    private var editorBackground: Color {
        isDark ? Color(red: 0.125, green: 0.145, blue: 0.133) : Color(red: 0.984, green: 0.988, blue: 0.976)
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
        .onAppear { load(); model.beginNoteEditing(annotation.id, session: noteSession, flush: { finished in
            flush(teardown: false, onFailure: { finished(.failure($0)) }) { finished(.success(())) }
        }) }
        .background(theme.surface)
        .foregroundStyle(theme.uiForeground)
        .colorScheme(theme.colorScheme)
        .onChange(of: text) { _, newValue in
            guard didLoad else { return }
            scheduleAutosave(newValue)
        }
        .onChange(of: mode) { _, newValue in
            onDrawActiveChanged?(newValue == .draw)
        }
        .onChange(of: isDark) { _, newValue in
            drawingController.setTheme(newValue ? "dark" : "light")
        }
        .onChange(of: annotation.visibleHighlightColor) { _, newValue in
            selectedColor = newValue
        }
        .onChange(of: annotation.note) { _, newValue in
            applyPersistedNote(newValue ?? "")
        }
        .interactiveDismissDisabled(mode == .draw || checkpointInFlight)
        .alert("Couldn’t save sketch", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onDisappear {
            guard !didDelete, model.annotation(with: annotation.id) != nil,
                  model.isNoteEditingSession(annotation.id, session: noteSession) else {
                drawingController.tearDown()
                model.endNoteEditing(annotation.id, session: noteSession)
                return
            }
            flush(completion: {
                model.sync.checkpoint()
                model.endNoteEditing(annotation.id, session: noteSession)
            })
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: presentation == .sidebar ? 14 : 26) {
            HStack(alignment: .center, spacing: 12) {
                if presentation == .sidebar, let onBack {
                    Button { flush(completion: { onBack() }) } label: {
                        Label("Notes", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .help("Back to notes")
                }

                Text(presentation == .sheet ? "The lines you come back to" : "Your margin")
                    .font(.system(size: presentation == .sheet ? 13 : 11, weight: .medium))
                    .foregroundStyle(theme.uiForeground.opacity(presentation == .sheet ? 0.88 : 0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(presentation == .sheet ? .center : .leading)

                if onAskAI != nil {
                    Button(action: askAIAboutHighlight) {
                        Image(systemName: "sparkles")
                            .font(.body.weight(.medium))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(QuietIconButtonStyle(theme: theme))
                    .help("Ask AI about this highlight")
                    .accessibilityLabel("Ask AI about this highlight")
                    .disabled(mode == .draw)
                }

                noteMenu

                if let onTogglePlacement {
                    Button { flush(teardown: false, completion: { onTogglePlacement() }) } label: {
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
                    Text("HIGHLIGHT / " + chapter.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.1)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }

                quote

                colorRow
            }
            .padding(.top, presentation == .sheet ? 18 : 10)
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

    private var quote: some View {
        Text(quoteAttributedString)
            .font(.system(size: presentation == .sidebar ? 20 : 28, weight: .regular, design: .serif))
            .lineSpacing(presentation == .sidebar ? 4 : 7)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var quoteAttributedString: AttributedString {
        var value = AttributedString(annotation.text)
        value.foregroundColor = theme.uiForeground
        if selectedColor == .underline {
            value.underlineStyle = .single
        } else {
            value.backgroundColor = selectedColor.swiftUIColor.opacity(isDark ? 0.28 : 0.40)
        }
        return value
    }

    private var colorRow: some View {
        HStack(spacing: 10) {
            Text("COLOR")
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
                .disabled(annotation.hasContent && color == .underline)
                .accessibilityLabel(color.displayName + " highlight")
                .accessibilityAddTraits(selectedColor == color ? [.isSelected] : [])
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

    private var noteMenu: some View {
        Menu {
            Button("Write") {
                sourceModeReason = sourceModeFallbackReason(for: text)
                switchMode(sourceModeReason == nil ? .edit : .source)
            }
            Button("Draw · Sketches") { switchMode(.sketches) }
            Divider()
            Button("Markdown Source") { switchMode(.source) }
            Button("Preview") { switchMode(.preview) }
            Divider()
            Menu("Export Note") {
                ForEach(NoteExportFormat.allCases, id: \.self) { format in
                    Button(format.label) { exportNote(format) }
                }
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !annotation.hasDrawing)
            Divider()
            Text("⌘B Bold · ⌘I Italic · ⌘U Underline")
            Text("⌘K Link · ⇧⌘X Strikethrough")
            Text("⌥⌘1 Heading · ⌥⌘0 Body")
            Text("⌥⌘7 Numbered list · ⌥⌘8 Bullets")
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 26, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Note options and keyboard shortcuts")
        .accessibilityLabel("Note options")
    }

    private var bodyEditor: some View {
        ZStack {
            writingSurface(source: false)
                .opacity(mode == .edit ? 1 : 0)
                .allowsHitTesting(mode == .edit)
                .accessibilityHidden(mode != .edit)
            VStack(alignment: .leading, spacing: 12) {
                if let sourceModeReason { unsupportedMarkdownBanner(sourceModeReason) }
                writingSurface(source: true)
            }
            .opacity(mode == .source ? 1 : 0)
            .allowsHitTesting(mode == .source)
            .accessibilityHidden(mode != .source)
            if mode == .preview {
                ScrollView {
                    NoteMarkdownPreview(text: text, sketchPreview: { model.sketchPreview(annotationID: annotation.id, sketchID: $0) }, onOpenSketch: openSketch)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 16)
                }
            }
            if mode == .sketches { sketchBrowser }
            if mode == .draw {
                VStack(spacing: 0) {
                    HStack {
                        Button("Back to note", systemImage: "chevron.left") { switchMode(returnMode) }
                        Spacer()
                        Text(activeSketch?.title ?? "New sketch").font(.subheadline)
                        Spacer()
                        Button("Sketches") { switchMode(.sketches) }
                    }
                    .padding(12)
                    ExcalidrawWebView(controller: drawingController)
                        .id(editorSession)
                        .onAppear { drawingController.focusCanvas() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sketches: [NoteSketch] { (model.annotation(with: annotation.id) ?? annotation).sketches }

    private var sketchBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("SKETCHES").font(.caption).foregroundStyle(theme.muted)
                    Spacer()
                    Button("New sketch", systemImage: "plus") { createSketch(at: NSRange(location: text.utf16.count, length: 0)) }
                }
                if sketches.isEmpty { Text("Draw a thought with /sketch or /draw in your note.").foregroundStyle(.secondary) }
                ForEach(sketches) { sketch in
                    VStack(alignment: .leading, spacing: 8) {
                        SketchPreviewCard(title: sketch.title, preview: model.sketchPreview(annotationID: annotation.id, sketchID: sketch.id)) { openSketch(sketch.id) }
                        HStack {
                            Button("Rename") { renameSketch(sketch) }
                            Spacer()
                            Button("Delete", role: .destructive) { deleteSketch(sketch.id) }
                        }
                        .font(.caption)
                    }
                }
            }.padding(horizontalPadding)
        }
        .id(previewRevision)
    }

    private func writingSurface(source: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(source ? "MARKDOWN SOURCE" : "MY NOTE")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(theme.muted.opacity(0.72))
                .padding(.horizontal, 8)
            if source {
                MarkdownTextEditor(text: $text, selectedRange: $selectedRange, isActive: mode == .source, isDark: isDark,
                                   placeholder: "Write your note…", onCreateSketch: createSketch,
                                   onOpenSketch: openSketch)
            } else {
                RichNoteEditor(text: $text, isDark: isDark, autofocus: autofocus, isActive: mode == .edit,
                               selectedRange: mode == .edit ? $selectedRange : nil,
                               preview: { model.sketchPreview(annotationID: annotation.id, sketchID: $0) },
                               onCreateSketch: createSketch, onOpenSketch: openSketch)
            }
        }
        .padding(.horizontal, horizontalPadding - 8)
        .padding(.top, presentation == .sheet ? 30 : 24)
        .padding(.bottom, 12)
    }

    private func unsupportedMarkdownBanner(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "curlybraces")
                .foregroundStyle(theme.accent)
            Text(reason)
                .font(.caption)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 14)
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                saveWork?.cancel()
                drawingWork?.cancel()
                didDelete = true
                editorSession = UUID()
                drawingController.onSceneChanged = nil
                drawingController.tearDown()
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
                    flush(teardown: false)
                }
                .font(.caption)
            }
            Button("Done") {
                flush(completion: { onClose() })
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(theme.accent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, presentation == .sheet ? 18 : 14)
        .background(editorBackground)
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

    private func load() {
        do { try model.migrateDrawing(for: annotation.id) }
        catch { saveStatus = .failed(error.localizedDescription) }
        text = (model.annotation(with: annotation.id) ?? annotation).note ?? ""
        lastSavedText = text
        sourceModeReason = sourceModeFallbackReason(for: text)
        selectedColor = annotation.visibleHighlightColor
        selectedRange = NSRange(location: (text as NSString).length, length: 0)
        if sourceModeReason != nil {
            mode = .source
        } else if autofocus {
            mode = .edit
        }
        didLoad = true
    }

    private func applyPersistedNote(_ value: String) {
        guard didLoad, value != lastSavedText else { return }
        saveWork?.cancel()
        lastSavedText = value
        text = value
        sourceModeReason = sourceModeFallbackReason(for: value)
        selectedRange = NSRange(location: (value as NSString).length, length: 0)
        saveStatus = .saved
    }

    private func createSketch(at range: NSRange) {
        guard !checkpointInFlight else { return }
        saveWork?.cancel()
        persistNote(text) { result in
            guard case .success = result else { return }
            returnMode = mode == .source ? .source : .edit
            draftRange = range
            shouldDiscardEmptyDraft = false
            let next = (sketches.compactMap { Int($0.title.replacingOccurrences(of: "Sketch ", with: "")) }.max() ?? 0) + 1
            activateSketch(NoteSketch(title: "Sketch \(next)"), scene: nil)
        }
    }

    private func openSketch(_ id: UUID) {
        guard let sketch = sketches.first(where: { $0.id == id }) else {
            errorMessage = "This sketch is unavailable. Wait for sync or restore its note from a backup."
            return
        }
        flush(teardown: false, completion: {
            guard let scene = model.sketchScene(annotationID: annotation.id, sketchID: id) else {
                errorMessage = "This sketch's drawing has not been downloaded or is missing. Try Sync Now."
                return
            }
            returnMode = mode == .source ? .source : .edit
            draftRange = nil
            if let reference = SketchReference.references(in: text).first(where: { $0.id == id }) { selectedRange = reference.range }
            activateSketch(sketch, scene: scene)
        })
    }

    private func activateSketch(_ sketch: NoteSketch, scene: Data?) {
        drawingWork?.cancel()
        drawingController.tearDown()
        drawingController = ExcalidrawController()
        let session = UUID()
        editorSession = session
        activeSketch = sketch
        sceneDirty = false
        pendingCheckpoint = false
        shouldDiscardEmptyDraft = false
        sceneRevision = 0
        drawingController.setTheme(isDark ? "dark" : "light")
        drawingController.load(scene: scene)
        drawingController.onSceneChanged = { _, _ in
            guard editorSession == session, !didDelete, mode == .draw, activeSketch?.id == sketch.id,
                  model.isNoteEditingSession(annotation.id, session: noteSession) else { return }
            sceneRevision += 1
            sceneDirty = true
            scheduleDrawingSave()
        }
        drawingController.onError = { message in
            guard editorSession == session else { return }
            saveStatus = .failed(message)
        }
        mode = .draw
    }

    private func switchMode(_ target: EditorMode) {
        flush(teardown: false, discardEmptyDraft: true, completion: {
            if mode == .draw {
                activeSketch = nil
                drawingController.tearDown()
            }
            mode = target
        })
    }

    private func renameSketch(_ sketch: NoteSketch) {
        let alert = NSAlert()
        alert.messageText = "Name this sketch"
        let field = NSTextField(string: sketch.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let updated = SketchReference.replacing(in: text) { $0.id == sketch.id ? SketchReference.markdown(id: sketch.id, title: title) : SketchReference.markdown(id: $0.id, title: $0.title) }
        do {
            try model.renameSketch(sketch.id, title: title, note: updated, annotationID: annotation.id)
            text = updated; lastSavedText = updated; previewRevision += 1
        } catch { saveStatus = .failed(error.localizedDescription) }
    }

    private func deleteSketch(_ id: UUID) {
        let updated = SketchReference.replacing(in: text) { $0.id == id ? "" : SketchReference.markdown(id: $0.id, title: $0.title) }
        model.updateNote(updated, for: annotation.id, reconcileSketches: true) { result in
            switch result {
            case .success: text = updated; lastSavedText = updated; previewRevision += 1
            case .failure(let error): saveStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func flush(teardown: Bool = true, discardEmptyDraft: Bool = false, onFailure: ((Error) -> Void)? = nil, completion: (() -> Void)? = nil) {
        guard !didDelete else { completion?(); return }
        saveWork?.cancel()
        drawingWork?.cancel()
        saveCanvas(discardEmptyDraft: teardown || discardEmptyDraft) { canvasResult in
            if case .failure(let error) = canvasResult { onFailure?(error); return }
            persistNote(text, reconcile: true) { result in
                if case .failure(let error) = result { onFailure?(error); return }
                if teardown { onDrawActiveChanged?(false); drawingController.tearDown(); activeSketch = nil }
                completion?()
            }
        }
    }

    private func saveCanvas(discardEmptyDraft: Bool = false, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard mode == .draw, let sketch = activeSketch else { completion?(.success(())); return }
        shouldDiscardEmptyDraft = shouldDiscardEmptyDraft || discardEmptyDraft
        guard !checkpointInFlight else {
            pendingCheckpoint = true
            if let completion { canvasWaiters.append(completion) }
            return
        }
        checkpointInFlight = true
        let revision = sceneRevision
        let session = editorSession
        saveStatus = .saving
        drawingController.checkpoint { result in
            guard session == editorSession, !didDelete else { return }
            checkpointInFlight = false
            guard model.isNoteEditingSession(annotation.id, session: noteSession) else {
                completeCanvasSave(completion, result: .failure(NSError(domain: "KodiSketch", code: 1, userInfo: [NSLocalizedDescriptionKey: "The note moved to another editor."])))
                return
            }
            switch result {
            case .success(let checkpoint):
                if checkpoint.elementCount == 0, draftRange != nil {
                    sceneDirty = false
                    if shouldDiscardEmptyDraft { discardDraft() }
                    shouldDiscardEmptyDraft = false
                    pendingCheckpoint = false
                    saveStatus = .saved
                    completeCanvasSave(completion)
                    return
                }
                var note = text
                if let range = draftRange {
                    let value = NSMutableString(string: text)
                    let location = min(range.location, value.length)
                    let length = min(range.length, value.length - location)
                    let before = location > 0 && value.substring(with: NSRange(location: location - 1, length: 1)) != "\n" ? "\n\n" : ""
                    let end = location + length
                    let after = end < value.length && value.substring(with: NSRange(location: end, length: 1)) != "\n" ? "\n\n" : "\n"
                    value.replaceCharacters(in: NSRange(location: location, length: length), with: before + sketch.markdown + after)
                    note = value as String
                }
                do {
                    try model.saveSketch(sketch, checkpoint: checkpoint, note: note, annotationID: annotation.id)
                    text = note; lastSavedText = note
                    if let reference = SketchReference.references(in: note).first(where: { $0.id == sketch.id }) {
                        selectedRange = NSRange(location: NSMaxRange(reference.range), length: 0)
                    }
                    draftRange = nil
                    shouldDiscardEmptyDraft = false
                    sceneDirty = sceneRevision != revision
                    previewRevision += 1
                    saveStatus = .saved
                    if sceneDirty || pendingCheckpoint {
                        pendingCheckpoint = false
                        saveCanvas(completion: completion)
                    } else { completeCanvasSave(completion) }
                } catch {
                    saveStatus = .failed(error.localizedDescription); errorMessage = error.localizedDescription
                    completeCanvasSave(completion, result: .failure(error))
                }
            case .failure(let error):
                saveStatus = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
                completeCanvasSave(completion, result: .failure(error))
            }
        }
    }

    private func discardDraft() {
        guard let range = draftRange else { return }
        let value = NSMutableString(string: text)
        if NSMaxRange(range) <= value.length { value.replaceCharacters(in: range, with: "") }
        text = value as String
        selectedRange = NSRange(location: min(range.location, text.utf16.count), length: 0)
        draftRange = nil
    }

    private func completeCanvasSave(_ completion: ((Result<Void, Error>) -> Void)?, result: Result<Void, Error> = .success(())) {
        let waiters = canvasWaiters
        canvasWaiters.removeAll()
        completion?(result)
        for waiter in waiters { waiter(result) }
    }

    private func exportNote(_ format: NoteExportFormat) {
        flush(teardown: false, completion: {
            if let snapshot = model.annotation(with: annotation.id) { model.exportNotes(format, annotations: [snapshot]) }
        })
    }

    private func askAIAboutHighlight() {
        guard let onAskAI else { return }
        saveWork?.cancel()
        persistNote(text) { result in
            if case .success = result {
                onAskAI()
            }
        }
    }

    private func scheduleAutosave(_ value: String) {
        saveWork?.cancel()
        guard value != lastSavedText else {
            saveStatus = .saved
            return
        }
        saveStatus = .saving
        let work = DispatchWorkItem {
            persistNote(value)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persistNote(
        _ value: String,
        reconcile: Bool = false,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        let referenceIDs = Set(SketchReference.references(in: value).map(\.id))
        let sketchIDs = Set(sketches.map(\.id))
        guard value != lastSavedText || (reconcile && referenceIDs != sketchIDs) else {
            saveStatus = .saved
            completion?(.success(()))
            return
        }
        saveRevision += 1
        let revision = saveRevision
        saveStatus = .saving
        onSave(value, reconcile || mode == .edit) { result in
            guard revision == saveRevision else {
                completion?(result)
                return
            }
            switch result {
            case .success:
                lastSavedText = value
                saveStatus = .saved
            case .failure(let error):
                saveStatus = .failed(error.localizedDescription)
            }
            completion?(result)
        }
    }

    private func sourceModeFallbackReason(for markdown: String) -> String? {
        let constructs = NoteMarkdown.unsupportedConstructs(in: markdown.replacingOccurrences(of: "</?u>", with: "", options: .regularExpression))
        if let reason = RichNoteCodec.sourceOnlyReason(markdown) {
            return "This note contains \(reason). Markdown source keeps its formatting intact."
        }
        guard !constructs.isEmpty else { return nil }
        let labels = constructs.map(\.label).joined(separator: ", ")
        return "This note contains \(labels), so it opens in Markdown source mode to preserve the original text."
    }

    private func scheduleDrawingSave() {
        saveStatus = .saving
        drawingWork?.cancel()
        let work = DispatchWorkItem { saveCanvas() }
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
    var isDark: Bool = false
    let onSave: (String, Bool, @escaping (Result<Void, Error>) -> Void) -> Void
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void
    var onAskAI: (() -> Void)? = nil
    var onTogglePlacement: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NoteEditor(
            annotation: annotation,
            autofocus: autofocus,
            presentation: .sheet,
            isDark: isDark,
            onSave: onSave,
            onChangeColor: onChangeColor,
            onDelete: onDelete,
            onClose: { dismiss() },
            onAskAI: onAskAI,
            onTogglePlacement: onTogglePlacement
        )
        .frame(minWidth: 520, idealWidth: 580, minHeight: 560, idealHeight: 640)
    }
}
