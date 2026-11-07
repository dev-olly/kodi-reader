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
    @State private var reminderDraft: ReminderDraft?
    @State private var reminderTitle = ""
    @State private var reminderError: String?
    @State private var isSavingReminder = false
    @FocusState private var reminderFieldFocused: Bool

    private struct ReminderDraft {
        var id = UUID()
        var bookID: String
        var existingID: UUID?
        var range: NSRange
        var command: String
    }
    @State private var audioDraftID: UUID?
    @State private var audioDraftOriginal = ""
    @State private var audioReturnMode: EditorMode = .edit
    @State private var audioStartTask: Task<Void, Never>?
    @State private var audioSaving = false
    @State private var audioSaveWaiters: [(Result<Void, Error>) -> Void] = []
    @State private var audioDraftError: String?
    @State private var expandedAudioTranscripts: Set<UUID> = []

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
                if reminderDraft != nil { reminderComposer }
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
        }); model.audioNotes.onRecordingStopped = { finishAudio() } }
        .background(theme.surface)
        .background(AnalyticsReaderEditorMarker())
        .foregroundStyle(theme.uiForeground)
        .colorScheme(theme.colorScheme)
        .onChange(of: text) { _, newValue in
            guard didLoad else { return }
            if let id = audioDraftID, !newValue.contains(AudioDraftReference.marker(id)), !audioSaving {
                // Native Undo may undo the insertion that started the take.
                // It must also stop the microphone when removing its controls.
                discardAudio()
            }
            scheduleAutosave(newValue)
        }
        .onChange(of: mode) { oldValue, newValue in
            if newValue == .draw { model.endTextNoteEditing(annotation.id, session: noteSession) }
            if oldValue == .draw, newValue != .draw {
                model.endSketchEditing(annotation.id, session: noteSession)
            }
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
        .interactiveDismissDisabled(mode == .draw || checkpointInFlight || audioDraftID != nil)
        .alert("Couldn’t complete note action", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
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
                model.audioNotes.stopPlayback()
                model.audioNotes.onRecordingStopped = nil
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
            Button("Add reminder", systemImage: "checklist") {
                beginReminder(at: NSRange(location: text.utf16.count, length: 0))
            }
            Button("Record audio", systemImage: "mic") { createAudio(at: selectedRange) }
                .disabled(audioDraftID != nil)
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
        .disabled(reminderDraft != nil)
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
                    NoteMarkdownPreview(
                        text: text,
                        sketchPreview: { model.sketchPreview(annotationID: annotation.id, sketchID: $0) },
                        sketchModifiedAt: sketchModifiedAt,
                        onOpenSketch: openSketch,
                        onRenameSketch: renameSketch,
                        audio: audioContext,
                        reminders: reminderContext
                    )
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
    private var recordings: [NoteAudio] { (model.annotation(with: annotation.id) ?? annotation).audioRecordings }

    private var audioContext: AudioNoteEditorContext {
        let scope = AudioTranscriptionScope(bookID: model.book?.bookID ?? "", annotationID: annotation.id)
        var errors = model.audioTranscriptionErrors[scope] ?? [:]
        if model.audioTranscription.errorScope == scope,
           let id = model.audioTranscription.errorID, let message = model.audioTranscription.errorMessage { errors[id] = message }
        return AudioNoteEditorContext(controller: model.audioNotes,
            recordings: Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }),
            fileURL: { model.audioURL(annotationID: annotation.id, audioID: $0) },
            onRename: renameAudio,
            onExport: { model.exportAudio($0, annotationID: annotation.id) },
            onDelete: deleteAudio,
            draftID: audioDraftID, draftError: audioDraftError,
            onFinishDraft: { finishAudio() }, onDiscardDraft: { discardAudio() },
            transcription: model.audioTranscription,
            transcriptionScope: scope,
            transcriptionBusyID: model.audioTranscription.activeScope == scope ? model.audioTranscription.activeID : nil,
            transcriptionErrors: errors, expandedTranscripts: expandedAudioTranscripts,
            onTranscribe: { id in
                model.transcribeAudio(id, annotationID: annotation.id) { success in
                    if success { expandedAudioTranscripts.insert(id) }
                }
            },
            onToggleTranscript: { id in
                if expandedAudioTranscripts.contains(id) { expandedAudioTranscripts.remove(id) }
                else { expandedAudioTranscripts.insert(id) }
            })
    }

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
                        SketchPreviewCard(
                            title: sketch.title,
                            preview: model.sketchPreview(annotationID: annotation.id, sketchID: sketch.id),
                            modifiedAt: sketch.modifiedAt,
                            isDark: isDark,
                            onRename: { renameSketch(sketch) }
                        ) { openSketch(sketch.id) }
                        HStack {
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

    private var isWritingActive: Bool {
        presentation == .sheet || model.workspace == .notes
    }

    private func writingSurface(source: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(source ? "MARKDOWN SOURCE" : "MY NOTE")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(theme.muted.opacity(0.72))
                .padding(.horizontal, 8)
            if source {
                MarkdownTextEditor(text: $text, selectedRange: $selectedRange, isEditable: reminderDraft == nil,
                                   isActive: mode == .source && isWritingActive, isDark: isDark,
                                   placeholder: "Write your note…", onCreateSketch: createSketch,
                                   onOpenSketch: openSketch, onCreateAudio: createAudio,
                                   onOpenAudio: playAudio, audioDraftID: audioDraftID, audioContext: audioContext,
                                   onCreateReminder: beginReminder, onOpenReminder: editReminder)
            } else {
                RichNoteEditor(text: $text, isDark: isDark, autofocus: autofocus, isActive: mode == .edit && isWritingActive,
                               isEditable: reminderDraft == nil,
                               selectedRange: mode == .edit ? $selectedRange : nil,
                               preview: { model.sketchPreview(annotationID: annotation.id, sketchID: $0) },
                               sketchModifiedAt: sketchModifiedAt,
                               onCreateSketch: createSketch, onOpenSketch: openSketch,
                               onRenameSketch: renameSketch, onCreateAudio: createAudio,
                               audio: audioContext, onCreateReminder: beginReminder,
                               reminders: reminderContext)
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
                onDelete()
                guard model.annotation(with: annotation.id) == nil else {
                    saveStatus = .failed(model.errorMessage ?? "Couldn’t delete the note. Your recording has been kept.")
                    return
                }
                didDelete = true
                audioStartTask?.cancel()
                audioDraftID = nil
                editorSession = UUID()
                drawingController.onSceneChanged = nil
                drawingController.tearDown()
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
            .disabled(reminderDraft != nil)
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
        if audioDraftID != nil { lastSavedText = value; return }
        saveWork?.cancel()
        lastSavedText = value
        text = value
        sourceModeReason = sourceModeFallbackReason(for: value)
        selectedRange = NSRange(location: (value as NSString).length, length: 0)
        saveStatus = .saved
    }

    private var reminderContext: ReminderNoteEditorContext {
        // Read the observable snapshot here so canonical title/completion changes
        // refresh native rows even when the note's Markdown remains unchanged.
        let reminders = model.record?.reminders ?? []
        return ReminderNoteEditorContext(reminder: { id in reminders.first { $0.id == id } },
                                         onToggle: toggleReminder, onEdit: editReminder)
    }

    private var reminderComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(reminderDraft?.existingID == nil ? "Add reminder" : "Edit reminder", systemImage: "checklist")
                .font(.system(size: 12, weight: .medium))
            TextField("Research database sharding…", text: $reminderTitle)
                .textFieldStyle(.roundedBorder)
                .focused($reminderFieldFocused)
                .onSubmit(saveReminderDraft)
                .disabled(isSavingReminder)
                .accessibilityLabel("Reminder topic")
            if let reminderError {
                Text(reminderError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("Saved to your reminders, linked to this note.")
                    .font(.caption2).foregroundStyle(theme.muted)
                Spacer(minLength: 8)
                Button("Cancel", action: cancelReminderDraft).disabled(isSavingReminder)
                Button(reminderDraft?.existingID == nil ? "Add" : "Save", action: saveReminderDraft)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .disabled(isSavingReminder || reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(theme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.border, lineWidth: 1))
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 12)
        .onExitCommand { if !isSavingReminder { cancelReminderDraft() } }
    }

    private func beginReminder(at range: NSRange) {
        guard audioDraftID == nil, !audioSaving else {
            saveStatus = .failed("Finish or discard the recording before adding a reminder.")
            return
        }
        guard reminderDraft == nil, !checkpointInFlight, let bookID = model.book?.bookID,
              NSMaxRange(range) <= text.utf16.count else { return }
        let command = (text as NSString).substring(with: range)
        reminderDraft = ReminderDraft(bookID: bookID, range: range, command: command)
        reminderTitle = NoteMarkdown.plainPreview(of: ReminderReference.commandTitle(in: command))
        reminderError = nil
        saveWork?.cancel()
        if reminderTitle.isEmpty { reminderFieldFocused = true }
        else { saveReminderDraft() }
    }

    private func editReminder(_ id: UUID) {
        guard reminderDraft == nil, let bookID = model.book?.bookID,
              let reminder = model.reminder(with: id, bookID: bookID) else { return }
        reminderDraft = ReminderDraft(bookID: bookID, existingID: id, range: selectedRange, command: "")
        reminderTitle = reminder.title
        reminderError = nil
        reminderFieldFocused = true
    }

    private func cancelReminderDraft() {
        let range = reminderDraft?.range
        reminderDraft = nil
        reminderError = nil
        reminderFieldFocused = false
        if let range { selectedRange = range }
        scheduleAutosave(text)
    }

    private func saveReminderDraft() {
        guard !isSavingReminder, let draft = reminderDraft else { return }
        let title = reminderTitle.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { reminderFieldFocused = true; return }
        guard model.book?.bookID == draft.bookID, !didDelete,
              model.annotation(with: annotation.id) != nil else {
            reminderError = "This note is no longer open. Your reminder text has been kept."
            return
        }
        isSavingReminder = true
        reminderError = nil
        saveWork?.cancel()
        // Commit preceding prose first, then checkpoint the reference and reminder
        // in the same BookRecord write. Failed writes leave the command untouched.
        persistNote(text) { result in
            guard case .success = result else {
                if case .failure(let error) = result { reminderError = error.localizedDescription }
                isSavingReminder = false
                return
            }
            do {
                guard model.book?.bookID == draft.bookID, !didDelete,
                      model.isNoteEditingSession(annotation.id, session: noteSession),
                      model.annotation(with: annotation.id) != nil else {
                    throw NSError(domain: "KodiReminder", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "The note moved to another editor. Your reminder text has been kept."])
                }
                if let id = draft.existingID {
                    guard var reminder = model.reminder(with: id, bookID: draft.bookID) else {
                        throw NSError(domain: "KodiReminder", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "This reminder is no longer available."])
                    }
                    reminder.title = title
                    try model.updateReminder(reminder, bookID: draft.bookID)
                } else {
                    let value = text as NSString
                    guard NSMaxRange(draft.range) <= value.length,
                          value.substring(with: draft.range) == draft.command else {
                        throw NSError(domain: "KodiReminder", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "The note changed while adding this reminder. Cancel and try again; your text is safe."])
                    }
                    let before = draft.range.location > 0 && value.substring(with: NSRange(location: draft.range.location - 1, length: 1)) != "\n" ? "\n\n" : ""
                    let after = NSMaxRange(draft.range) < value.length && value.substring(with: NSRange(location: NSMaxRange(draft.range), length: 1)) != "\n" ? "\n\n" : "\n"
                    let reference = ReminderReference.markdown(id: draft.id, title: title)
                    let insertion = before + reference + after
                    let updated = value.replacingCharacters(in: draft.range, with: insertion)
                    guard ReminderReference.references(in: updated).contains(where: { $0.id == draft.id }) else {
                        throw NSError(domain: "KodiReminder", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "Add a reminder on an empty paragraph outside code. Cancel to move the cursor; your topic has been kept here."])
                    }
                    _ = try model.createReminder(title: title, source: .note, locator: annotation.locator,
                        quotedText: annotation.text, chapterTitle: annotation.chapterTitle,
                        annotationID: annotation.id, id: draft.id, noteUpdate: updated)
                    saveRevision += 1
                    lastSavedText = updated
                    text = updated
                    selectedRange = NSRange(location: draft.range.location + insertion.utf16.count, length: 0)
                    saveStatus = .saved
                }
                reminderDraft = nil
                reminderFieldFocused = false
            } catch { reminderError = error.localizedDescription }
            isSavingReminder = false
        }
    }

    /// Navigation keeps an unfinished new topic as a slash-command draft in
    /// the note. Merely closing the editor must never create a research task.
    private func checkpointReminderDraft() throws {
        guard let draft = reminderDraft else { return }
        let title = reminderTitle.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isSavingReminder || (draft.existingID != nil && model.reminder(with: draft.existingID!, bookID: draft.bookID)?.title != title) {
            throw NSError(domain: "KodiReminder", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Save or cancel the reminder edit before leaving this note."])
        }
        if draft.existingID == nil, !title.isEmpty {
            let value = text as NSString
            guard NSMaxRange(draft.range) <= value.length,
                  value.substring(with: draft.range) == draft.command else {
                throw NSError(domain: "KodiReminder", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The note changed while adding this reminder. Cancel and try again; your text is safe."])
            }
            let before = draft.range.location > 0 && value.substring(with: NSRange(location: draft.range.location - 1, length: 1)) != "\n" ? "\n\n" : ""
            let after = NSMaxRange(draft.range) < value.length && value.substring(with: NSRange(location: NSMaxRange(draft.range), length: 1)) != "\n" ? "\n\n" : ""
            text = value.replacingCharacters(in: draft.range, with: before + "/remind " + title + after)
        }
        reminderDraft = nil
        reminderFieldFocused = false
    }

    private func toggleReminder(_ id: UUID) {
        guard let bookID = model.book?.bookID, var reminder = model.reminder(with: id, bookID: bookID) else { return }
        reminder.completedAt = reminder.isCompleted ? nil : Date()
        do { try model.updateReminder(reminder, bookID: bookID) }
        catch { saveStatus = .failed(error.localizedDescription) }
    }

    private func createSketch(at range: NSRange) {
        guard audioDraftID == nil, !audioSaving else {
            saveStatus = .failed("Finish or discard the recording before creating a sketch.")
            return
        }
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
            model.recordSketchOpened(annotationID: annotation.id, sketchID: id)
        })
    }

    private func activateSketch(_ sketch: NoteSketch, scene: Data?) {
        model.endSketchEditing(annotation.id, session: noteSession)
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

    private func sketchModifiedAt(_ id: UUID) -> Date? {
        sketches.first(where: { $0.id == id })?.modifiedAt
    }

    private func createAudio(at range: NSRange) {
        guard audioDraftID == nil, !audioSaving, reminderDraft == nil else { return }
        guard model.audioNotes.recordingID == nil else {
            errorMessage = "Finish or discard the recording in the other note first."
            return
        }
        let prefix = (text as NSString).substring(to: min(range.location, text.utf16.count))
        let probe = UUID()
        guard AudioReference.references(in: prefix + "\n\n" + AudioReference.markdown(id: probe, title: "audio")).contains(where: { $0.id == probe }) else {
            errorMessage = "Move the cursor outside the code block to record an audio note."
            return
        }
        flush(teardown: false, completion: {
            let id = UUID()
            let value = NSMutableString(string: text)
            let location = min(range.location, value.length)
            let length = min(range.length, value.length - location)
            let prefix = value.substring(to: location)
            let suffix = value.substring(from: location + length)
            let before = String(repeating: "\n", count: max(0, 2 - prefix.reversed().prefix(while: { $0 == "\n" }).count))
            let after = suffix.isEmpty ? "\n" : String(repeating: "\n", count: max(0, 2 - suffix.prefix(while: { $0 == "\n" }).count))
            audioDraftOriginal = value.substring(with: NSRange(location: location, length: length))
            audioDraftID = id
            audioDraftError = nil
            audioReturnMode = mode == .source ? .source : .edit
            let marker = AudioDraftReference.marker(id)
            value.replaceCharacters(in: NSRange(location: location, length: length), with: (prefix.isEmpty ? "" : before) + marker + after)
            text = value as String
            selectedRange = NSRange(location: min(text.utf16.count, location + before.utf16.count + marker.utf16.count + after.utf16.count), length: 0)
            mode = sourceModeReason == nil ? .edit : .preview
            audioStartTask = Task { @MainActor in
                do {
                    try await model.audioNotes.startRecording(id: id, annotationID: annotation.id)
                } catch {
                    guard audioDraftID == id else { return }
                    discardAudio(restoreCommand: true)
                    errorMessage = error.localizedDescription
                }
                if audioDraftID == id { audioStartTask = nil }
            }
        })
    }

    private func finishAudio(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let id = audioDraftID else { completion?(.success(())); return }
        if let completion { audioSaveWaiters.append(completion) }
        guard !audioSaving else { return }
        audioSaving = true
        audioDraftError = nil
        saveStatus = .saving
        let start = audioStartTask
        Task { @MainActor in
            await start?.value
            guard audioDraftID == id, !didDelete else {
                completeAudioSave(.success(())); return
            }
            if model.audioNotes.elapsed == 0, !model.audioNotes.canFinish {
                discardAudio()
                completeAudioSave(.success(())); return
            }
            do {
                let take = try await model.audioNotes.finishRecording()
                guard audioDraftID == id, !didDelete,
                      model.isNoteEditingSession(annotation.id, session: noteSession) else {
                    throw NSError(domain: "KodiAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "The note moved to another editor before the recording could be saved."])
                }
                let next = (recordings.compactMap { Int($0.title.replacingOccurrences(of: "Audio note ", with: "")) }.max() ?? 0) + 1
                let audio = NoteAudio(id: id, title: "Audio note \(next)", duration: take.duration, waveform: take.waveform)
                var updated = text
                let marker = AudioDraftReference.marker(id)
                if updated.contains(marker) { updated = updated.replacingOccurrences(of: marker, with: audio.markdown) }
                else { updated += (updated.isEmpty ? "" : "\n\n") + audio.markdown + "\n" }
                saveWork?.cancel()
                try model.saveAudio(audio, from: take.url, note: updated, annotationID: annotation.id)
                model.audioNotes.markRecordingSaved()
                audioDraftID = nil
                audioDraftOriginal = ""
                audioDraftError = nil
                text = updated
                lastSavedText = updated
                previewRevision += 1
                saveStatus = .saved
                if mode == .preview { mode = audioReturnMode }
                if let reference = AudioReference.references(in: updated).first(where: { $0.id == id }) {
                    selectedRange = NSRange(location: NSMaxRange(reference.range), length: 0)
                }
                completeAudioSave(.success(()))
            } catch {
                guard audioDraftID == id else { completeAudioSave(.success(())); return }
                audioDraftError = error.localizedDescription
                saveStatus = .failed(error.localizedDescription)
                completeAudioSave(.failure(error))
            }
        }
    }

    private func completeAudioSave(_ result: Result<Void, Error>) {
        audioSaving = false
        let waiters = audioSaveWaiters
        audioSaveWaiters.removeAll()
        for waiter in waiters { waiter(result) }
    }

    private func discardAudio(restoreCommand: Bool = false) {
        guard let id = audioDraftID else { return }
        audioStartTask?.cancel()
        audioStartTask = nil
        if model.audioNotes.recordingID == id { model.audioNotes.discardRecording() }
        text = text.replacingOccurrences(of: AudioDraftReference.marker(id), with: restoreCommand ? audioDraftOriginal : "")
        audioDraftID = nil
        audioDraftOriginal = ""
        audioDraftError = nil
        saveStatus = .saved
        if mode == .preview { mode = audioReturnMode }
    }

    private func playAudio(_ id: UUID) {
        guard let url = model.audioURL(annotationID: annotation.id, audioID: id) else {
            errorMessage = "This recording is unavailable. Wait for it to download or try Sync Now."
            return
        }
        do { try model.audioNotes.play(id: id, url: url) }
        catch { errorMessage = error.localizedDescription }
    }

    private func renameAudio(_ id: UUID) {
        guard let audio = recordings.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Name this recording"
        let field = NSTextField(string: audio.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let updated = AudioReference.replacing(in: text) { reference in
            AudioReference.markdown(id: reference.id, title: reference.id == id ? title : reference.title)
        }
        let durable = AudioDraftReference.removing(audioDraftID, from: updated)
        do {
            try model.renameAudio(id, title: title, note: durable, annotationID: annotation.id)
            text = updated; lastSavedText = durable; previewRevision += 1
        } catch { saveStatus = .failed(error.localizedDescription) }
    }

    private func deleteAudio(_ id: UUID) {
        let updated = AudioReference.replacing(in: text) { reference in
            reference.id == id ? "" : AudioReference.markdown(id: reference.id, title: reference.title)
        }
        let durable = AudioDraftReference.removing(audioDraftID, from: updated)
        model.updateNote(durable, for: annotation.id, reconcileSketches: true) { result in
            switch result {
            case .success: text = updated; lastSavedText = durable; previewRevision += 1
            case .failure(let error): saveStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func renameSketch(_ id: UUID) {
        guard let sketch = sketches.first(where: { $0.id == id }) else { return }
        renameSketch(sketch)
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
            let durable = AudioDraftReference.removing(audioDraftID, from: updated)
            try model.renameSketch(sketch.id, title: title, note: durable, annotationID: annotation.id)
            text = updated; lastSavedText = durable; previewRevision += 1
        } catch { saveStatus = .failed(error.localizedDescription) }
    }

    private func deleteSketch(_ id: UUID) {
        let updated = SketchReference.replacing(in: text) { $0.id == id ? "" : SketchReference.markdown(id: $0.id, title: $0.title) }
        let durable = AudioDraftReference.removing(audioDraftID, from: updated)
        model.updateNote(durable, for: annotation.id, reconcileSketches: true) { result in
            switch result {
            case .success: text = updated; lastSavedText = durable; previewRevision += 1
            case .failure(let error): saveStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func flush(teardown: Bool = true, discardEmptyDraft: Bool = false, onFailure: ((Error) -> Void)? = nil, completion: (() -> Void)? = nil) {
        guard !didDelete else { completion?(); return }
        do { try checkpointReminderDraft() }
        catch { reminderError = error.localizedDescription; onFailure?(error); return }
        saveWork?.cancel()
        drawingWork?.cancel()
        finishAudio { audioResult in
            if case .failure(let error) = audioResult { onFailure?(error); return }
            saveCanvas(discardEmptyDraft: teardown || discardEmptyDraft) { canvasResult in
                if case .failure(let error) = canvasResult { onFailure?(error); return }
                persistNote(text, reconcile: true) { result in
                    if case .failure(let error) = result { onFailure?(error); return }
                    if teardown { onDrawActiveChanged?(false); drawingController.tearDown(); activeSketch = nil }
                    completion?()
                }
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
        flush(teardown: false, completion: onAskAI)
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
        let value = AudioDraftReference.removing(audioDraftID, from: value)
        let referenceIDs = Set(SketchReference.references(in: value).map(\.id))
        let sketchIDs = Set(sketches.map(\.id))
        let audioIDs = Set(AudioReference.references(in: value).map(\.id))
        let savedAudioIDs = Set(recordings.map(\.id))
        guard value != lastSavedText || (reconcile && (referenceIDs != sketchIDs || audioIDs != savedAudioIDs)) else {
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
