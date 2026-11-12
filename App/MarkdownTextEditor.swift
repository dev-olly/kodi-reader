import AppKit
import EpubKit
import SwiftUI

/// Source editor for advanced Markdown that cannot be safely round-tripped.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var isEditable: Bool = true
    var isActive: Bool = true
    var isDark: Bool = false
    var placeholder: String? = nil
    var onCreateSketch: ((NSRange) -> Void)? = nil
    var onOpenSketch: ((UUID) -> Void)? = nil
    var onCreateAudio: ((NSRange) -> Void)? = nil
    var onOpenAudio: ((UUID) -> Void)? = nil
    var audioDraftID: UUID? = nil
    var audioContext: AudioNoteEditorContext? = nil
    var onCreateReminder: ((NSRange) -> Void)? = nil
    var onOpenReminder: ((UUID) -> Void)? = nil

    private static let containerInset = NSSize(width: 8, height: 10)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = NoteTextView()
        textView.delegate = context.coordinator
        textView.commandEnabled = isActive && isEditable
        textView.commandIsDark = isDark
        textView.onCreateSketch = onCreateSketch
        textView.onOpenSketch = onOpenSketch
        textView.onCreateAudio = onCreateAudio
        textView.onOpenAudio = onOpenAudio
        textView.audioContext = audioContext
        textView.onCreateReminder = onCreateReminder
        textView.onOpenReminder = onOpenReminder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.textContainerInset = Self.containerInset
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.drawsBackground = false
        textView.isEditable = isEditable
        textView.placeholderString = placeholder ?? ""
        applySelection(selectedRange, to: textView)

        scroll.documentView = textView
        scroll.isHidden = !isActive

        context.coordinator.textView = textView
        context.coordinator.wasActive = isActive
        context.coordinator.parent = self
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if !isActive, textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
        scroll.isHidden = !isActive
        textView.isEditable = isEditable && isActive
        textView.commandEnabled = isActive && isEditable
        textView.commandIsDark = isDark
        textView.onCreateSketch = onCreateSketch
        textView.onOpenSketch = onOpenSketch
        textView.onCreateAudio = onCreateAudio
        textView.onOpenAudio = onOpenAudio
        textView.audioContext = audioContext
        textView.onCreateReminder = onCreateReminder
        textView.onOpenReminder = onOpenReminder
        if textView.string != text {
            context.coordinator.loading = true
            textView.insertText(text, replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
            context.coordinator.loading = false
        }

        if textView.selectedRange() != selectedRange {
            context.coordinator.loading = true
            applySelection(selectedRange, to: textView)
            context.coordinator.loading = false
        }

        if isActive && !context.coordinator.wasActive { textView.window?.makeFirstResponder(textView) }
        context.coordinator.wasActive = isActive
        context.coordinator.refreshPlaceholder()
    }

    /// Fill the proposed box instead of reporting the text view's unbounded
    /// intrinsic height, which retriggers inspector constraint updates.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        let height = proposal.height ?? nsView.bounds.height
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private func applySelection(_ range: NSRange, to textView: NSTextView) {
        let max = (textView.string as NSString).length
        let location = min(range.location, max)
        let length = min(range.length, max - location)
        let clamped = NSRange(location: location, length: length)
        textView.setSelectedRange(clamped)
        textView.scrollRangeToVisible(clamped)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        fileprivate weak var textView: NoteTextView?
        var loading = false
        var wasActive = false

        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
        }

        func refreshPlaceholder() {
            guard let textView else { return }
            textView.placeholderString = parent.placeholder ?? ""
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !loading else { return }
            parent.text = textView.string
            parent.selectedRange = textView.selectedRange()
            textView.commandChanged()
            refreshPlaceholder()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            guard !loading, parent.isActive else { return }
            parent.selectedRange = textView.selectedRange()
            self.textView?.commandChanged()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if let view = self.textView, view.handleSketchCommand(commandSelector) { return true }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            return insertListAwareNewline(in: textView)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !loading, let id = parent.audioDraftID else { return true }
            let marker = (textView.string as NSString).range(of: AudioDraftReference.marker(id))
            guard marker.location != NSNotFound else { return true }
            return NSIntersectionRange(marker, affectedCharRange).length == 0
                && !(affectedCharRange.location > marker.location && affectedCharRange.location < NSMaxRange(marker))
        }

        /// Continues `- ` / `* ` / `+ ` / `1. ` lists on Enter; exits on an empty item.
        private func insertListAwareNewline(in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let selected = textView.selectedRange()
            guard selected.length == 0 else { return false }

            let caret = selected.location
            let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
            var line = ns.substring(with: lineRange)
            if line.hasSuffix("\n") {
                line.removeLast()
            }

            guard let match = ListLine.match(line) else { return false }

            if match.content.isEmpty {
                // Empty item → exit the list by clearing the marker.
                if textView.shouldChangeText(in: lineRange, replacementString: "") {
                    textView.replaceCharacters(in: lineRange, with: "")
                    textView.didChangeText()
                    parent.text = textView.string
                    parent.selectedRange = textView.selectedRange()
                    refreshPlaceholder()
                }
                return true
            }

            let insertion = "\n" + match.indent + match.nextMarker
            if textView.shouldChangeText(in: selected, replacementString: insertion) {
                textView.replaceCharacters(in: selected, with: insertion)
                textView.didChangeText()
                parent.text = textView.string
                parent.selectedRange = textView.selectedRange()
                refreshPlaceholder()
            }
            return true
        }
    }
}

/// Owns slash suggestions in the native editor so their position and keyboard
/// handling follow the caret, including inside a SwiftUI sheet with buttons.
private enum NoteInsertCommand: Hashable {
    case sketch, audio, reminder
    var label: String {
        switch self { case .sketch: return "Create sketch"; case .audio: return "Record audio"; case .reminder: return "Add reminder" }
    }
    var symbol: String {
        switch self { case .sketch: return "pencil.tip.crop.circle"; case .audio: return "mic"; case .reminder: return "checklist" }
    }
}

class SketchCommandTextView: NSTextView {
    var onCreateSketch: ((NSRange) -> Void)?
    var onCreateAudio: ((NSRange) -> Void)?
    var onCreateReminder: ((NSRange) -> Void)?
    var commandEnabled = true { didSet { if !commandEnabled { hideCommandSuggestion() } } }
    var commandIsDark = false
    private var dismissedCommand: NSRange?
    private var suggestionPanel: NSPanel?
    private var suggestedCommands: [NoteInsertCommand] = []
    private var selectedCommand = 0
    var isCommandSuggestionVisible: Bool { suggestionPanel?.isVisible == true }

    func commandCandidate() -> NSRange? {
        SketchReference.commandSuggestionRange(in: string, selection: selectedRange())
            ?? AudioReference.commandSuggestionRange(in: string, selection: selectedRange())
            ?? ReminderReference.commandSuggestionRange(in: string, selection: selectedRange())
    }

    private func commandsAtCaret() -> [NoteInsertCommand] {
        var commands: [NoteInsertCommand] = []
        if onCreateSketch != nil, SketchReference.commandSuggestionRange(in: string, selection: selectedRange()) != nil { commands.append(.sketch) }
        if onCreateAudio != nil, AudioReference.commandSuggestionRange(in: string, selection: selectedRange()) != nil { commands.append(.audio) }
        if onCreateReminder != nil, ReminderReference.commandSuggestionRange(in: string, selection: selectedRange()) != nil { commands.append(.reminder) }
        return commands
    }

    func commandChanged() {
        let candidate = commandCandidate()
        let commands = commandsAtCaret()
        if suggestedCommands != commands { selectedCommand = 0 }
        suggestedCommands = commands
        if candidate != dismissedCommand { dismissedCommand = nil }
        guard commandEnabled, !commands.isEmpty, candidate != nil,
              candidate != dismissedCommand, let window, window.firstResponder === self,
              !isHiddenOrHasHiddenAncestor else { hideCommandSuggestion(); return }
        let panel: NSPanel
        if let existing = suggestionPanel { panel = existing }
        else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 244, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            suggestionPanel = panel
        }
        panel.setContentSize(NSSize(width: 244, height: 44 * commands.count))
        panel.contentView = NSHostingView(rootView: SketchCommandSuggestion(commands: commands, selected: selectedCommand) { [weak self] command in
            self?.activate(command)
        })
        panel.appearance = NSAppearance(named: commandIsDark ? .darkAqua : .aqua)
        let commandStart = (SketchReference.commandSuggestionRange(in: string, selection: selectedRange())
            ?? AudioReference.commandSuggestionRange(in: string, selection: selectedRange())
            ?? ReminderReference.commandSuggestionRange(in: string, selection: selectedRange()))?.location ?? selectedRange().location
        let caret = firstRect(forCharacterRange: NSRange(location: commandStart, length: 0), actualRange: nil)
        // An insertion caret has zero width; its line height supplies the anchor.
        guard caret.height > 0 else { hideCommandSuggestion(); return }
        let localCaret = convert(window.convertFromScreen(caret), from: nil)
        guard visibleRect.intersects(localCaret.insetBy(dx: -1, dy: 0)) else { hideCommandSuggestion(); return }
        let screen = window.screen?.visibleFrame ?? caret
        var origin = NSPoint(x: min(max(caret.minX, screen.minX + 8), screen.maxX - panel.frame.width - 8),
                             y: caret.minY - panel.frame.height - 6)
        if origin.y < screen.minY + 8 { origin.y = caret.maxY + 6 }
        panel.setFrameOrigin(origin)
        if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func suppressPastedCommand() {
        dismissedCommand = commandCandidate()
        hideCommandSuggestion()
    }

    func handleSketchCommand(_ selector: Selector) -> Bool {
        guard commandEnabled, let range = commandCandidate(), range != dismissedCommand else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            dismissedCommand = range
            hideCommandSuggestion()
            return true
        }
        let commands = commandsAtCaret()
        if selector == #selector(NSResponder.moveDown(_:)), !commands.isEmpty {
            selectedCommand = (selectedCommand + 1) % commands.count
            commandChanged(); return true
        }
        if selector == #selector(NSResponder.moveUp(_:)), !commands.isEmpty {
            selectedCommand = (selectedCommand + commands.count - 1) % commands.count
            commandChanged(); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)), !commands.isEmpty {
            activate(commands[min(selectedCommand, commands.count - 1)], range: range)
            return true
        }
        return false
    }

    private func activate(_ command: NoteInsertCommand, range: NSRange? = nil) {
        guard let range = range ?? commandCandidate() else { return }
        hideCommandSuggestion()
        switch command {
        case .sketch: onCreateSketch?(range)
        case .audio: onCreateAudio?(range)
        case .reminder: onCreateReminder?(range)
        }
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 36, 76: return handleSketchCommand(#selector(NSResponder.insertNewline(_:)))
        case 53: return handleSketchCommand(#selector(NSResponder.cancelOperation(_:)))
        case 125: return handleSketchCommand(#selector(NSResponder.moveDown(_:)))
        case 126: return handleSketchCommand(#selector(NSResponder.moveUp(_:)))
        default: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleCommandKey(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleCommandKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if !handleSketchCommand(#selector(NSResponder.insertNewline(_:))) { super.insertNewline(sender) }
    }

    override func cancelOperation(_ sender: Any?) {
        if !handleSketchCommand(#selector(NSResponder.cancelOperation(_:))) { super.cancelOperation(sender) }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { hideCommandSuggestion() }
        return resigned
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { DispatchQueue.main.async { [weak self] in self?.commandChanged() } }
        return became
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideCommandSuggestion()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(commandViewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func commandViewportChanged() { commandChanged() }

    private func hideCommandSuggestion() {
        suggestionPanel?.orderOut(nil)
        if let panel = suggestionPanel { panel.parent?.removeChildWindow(panel) }
    }
}

private struct SketchCommandSuggestion: View {
    let commands: [NoteInsertCommand]
    let selected: Int
    var activate: (NoteInsertCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                Button { activate(command) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.symbol).frame(width: 18)
                        Text(command.label).fontWeight(.medium)
                        Spacer(minLength: 8)
                        if index == selected { Text("↵ Enter").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 44)
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                    .background(index == selected ? Color.primary.opacity(0.06) : .clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(command.label + (index == selected ? ", Enter" : ""))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.12), lineWidth: 1))
    }
}

/// Draws the placeholder in the extra line fragment so it shares the caret’s line.
final class NoteTextView: SketchCommandTextView {
    var onOpenSketch: ((UUID) -> Void)?
    var onOpenAudio: ((UUID) -> Void)?
    var audioContext: AudioNoteEditorContext?

    override func copy(_ sender: Any?) {
        let selected = (string as NSString).substring(with: selectedRange())
        AudioNoteClipboard.retain(selected, context: audioContext)
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }
    var onOpenReminder: ((UUID) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let layoutManager, let textContainer {
            let point = convert(event.locationInWindow, from: nil)
            let index = layoutManager.characterIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y), in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            if let reference = SketchReference.references(in: string).first(where: { NSLocationInRange(index, $0.range) }) {
                onOpenSketch?(reference.id)
                return
            }
            if let reference = ReminderReference.references(in: string).first(where: { NSLocationInRange(index, $0.range) }) {
                onOpenReminder?(reference.id)
                return
            }
            if let reference = AudioReference.references(in: string).first(where: { NSLocationInRange(index, $0.range) }) {
                onOpenAudio?(reference.id)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        suppressPastedCommand()
    }

    var placeholderString: String = "" {
        didSet {
            if oldValue != placeholderString {
                needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if string.isEmpty, !placeholderString.isEmpty {
            drawPlaceholder()
        }
        super.draw(dirtyRect)
    }

    private func drawPlaceholder() {
        let font = self.font ?? .systemFont(ofSize: NSFont.systemFontSize + 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        (placeholderString as NSString).draw(
            with: placeholderRect(for: font),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes
        )
    }

    /// Same box the insertion point uses when the document is empty.
    private func placeholderRect(for font: NSFont) -> NSRect {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = textContainerOrigin
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let fragment = layoutManager.extraLineFragmentRect
            if fragment.height > 0 {
                var rect = fragment.offsetBy(dx: origin.x, dy: origin.y)
                rect.origin.x += padding
                rect.size.width = max(0, bounds.width - rect.origin.x - textContainerInset.width)
                return rect
            }
        }
        return NSRect(
            x: origin.x + padding,
            y: origin.y,
            width: max(0, bounds.width - origin.x - padding - textContainerInset.width),
            height: layoutManager?.defaultLineHeight(for: font) ?? font.boundingRectForFont.height
        )
    }
}

private struct ListLine {
    let indent: String
    let nextMarker: String
    let content: String

    static func match(_ line: String) -> ListLine? {
        let pattern = #"^(\s*)([-*+]|\d+\.)\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let result = regex.firstMatch(in: line, range: range),
              result.numberOfRanges == 4,
              let indentRange = Range(result.range(at: 1), in: line),
              let markerRange = Range(result.range(at: 2), in: line),
              let contentRange = Range(result.range(at: 3), in: line)
        else {
            return nil
        }

        let indent = String(line[indentRange])
        let marker = String(line[markerRange])
        let content = String(line[contentRange])

        let nextMarker: String
        if marker == "-" || marker == "*" || marker == "+" {
            nextMarker = "\(marker) "
        } else if marker.hasSuffix("."), let number = Int(marker.dropLast()) {
            nextMarker = "\(number + 1). "
        } else {
            return nil
        }

        return ListLine(indent: indent, nextMarker: nextMarker, content: content)
    }
}

// Rich text is projected to Markdown at the persistence boundary. The original
// Markdown is left untouched until an actual edit, including opening/closing.
struct RichNoteEditor: NSViewRepresentable {
    @Binding var text: String
    var isDark: Bool
    var autofocus: Bool
    var isActive: Bool = true
    var isEditable: Bool = true
    var selectedRange: Binding<NSRange>? = nil
    var preview: ((UUID) -> Data?)? = nil
    var sketchModifiedAt: ((UUID) -> Date?)? = nil
    var onCreateSketch: ((NSRange) -> Void)? = nil
    var onOpenSketch: ((UUID) -> Void)? = nil
    var onRenameSketch: ((UUID) -> Void)? = nil
    var onCreateAudio: ((NSRange) -> Void)? = nil
    var audio: AudioNoteEditorContext? = nil
    var onCreateReminder: ((NSRange) -> Void)? = nil
    var reminders: ReminderNoteEditorContext? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        // Sketch layout and caret drawing both use NSLayoutManager.
        let view = RichNoteTextView(usingTextLayoutManager: false)
        view.isRichText = true
        view.isEditable = isEditable
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = NSSize(width: 8, height: 4)
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.setAccessibilityLabel("My note")
        view.delegate = context.coordinator
        scroll.documentView = view
        scroll.isHidden = !isActive
        context.coordinator.view = view
        context.coordinator.load(text, dark: isDark)
        context.coordinator.wasActive = isActive
        if autofocus && isActive {
            DispatchQueue.main.async { [weak view] in
                guard let view, !view.isHiddenOrHasHiddenAncestor else { return }
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        scroll.isHidden = !isActive
        if let view = coordinator.view {
            if !isActive, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
            view.onCreateSketch = onCreateSketch; view.onOpenSketch = onOpenSketch
            view.onRenameSketch = onRenameSketch
            view.onCreateAudio = onCreateAudio
            view.audioContext = audio
            view.onCreateReminder = onCreateReminder
            view.reminderContext = reminders
            view.sketchPreview = preview
            view.sketchModifiedAt = sketchModifiedAt
            view.isEditable = isEditable && isActive
            view.commandEnabled = isActive && isEditable
            view.commandIsDark = isDark
            var previewChanged = false
            view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.string.utf16.count)) { value, _, _ in
                if let card = value as? SketchTextAttachment, let cell = card.attachmentCell as? SketchAttachmentCell {
                    let image = preview?(card.id)
                    let modifiedAt = sketchModifiedAt?(card.id)
                    previewChanged = previewChanged || cell.preview != image || cell.modifiedAt != modifiedAt || cell.isDark != isDark
                    cell.preview = image
                    cell.modifiedAt = modifiedAt
                    cell.isDark = isDark
                }
            }
            view.resizeSketchCards()
            if previewChanged { view.needsDisplay = true }
        }
        if coordinator.lastMarkdown != text {
            coordinator.load(text, dark: isDark)
        } else if let view = coordinator.view, view.dark != isDark {
            view.dark = isDark
            let range = NSRange(location: 0, length: view.string.utf16.count)
            view.textStorage?.addAttribute(.foregroundColor, value: RichNoteCodec.ink(isDark), range: range)
            view.insertionPointColor = RichNoteCodec.ink(isDark)
            view.typingAttributes[.foregroundColor] = RichNoteCodec.ink(isDark)
            view.needsDisplay = true
        }
        coordinator.view?.refreshAudioOverlays(updateContent: true)
        if let selection = selectedRange?.wrappedValue, let view = coordinator.view, let storage = view.textStorage {
            if RichNoteCodec.markdownRange(view.selectedRange(), in: storage) != selection {
                coordinator.loading = true
                let range = RichNoteCodec.richRange(selection, in: storage)
                view.setSelectedRange(range)
                view.scrollRangeToVisible(range)
                coordinator.loading = false
            }
            if !coordinator.wasActive { view.window?.makeFirstResponder(view) }
        }
        coordinator.wasActive = isActive
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichNoteEditor
        weak var view: RichNoteTextView?
        var lastMarkdown = ""
        var loading = false
        var hasLoaded = false
        var wasActive = false
        init(_ parent: RichNoteEditor) { self.parent = parent }

        func load(_ markdown: String, dark: Bool) {
            guard let view else { return }
            loading = true
            let selection = view.selectedRange()
            view.dark = dark
            let decoded = RichNoteCodec.decode(markdown, dark: dark, preview: parent.preview, sketchModifiedAt: parent.sketchModifiedAt, audioDraftID: parent.audio?.draftID)
            if hasLoaded { view.insertText(decoded, replacementRange: NSRange(location: 0, length: view.string.utf16.count)) }
            else { view.textStorage?.setAttributedString(decoded); hasLoaded = true }
            view.onOpenSketch = parent.onOpenSketch
            view.onRenameSketch = parent.onRenameSketch
            view.onCreateSketch = parent.onCreateSketch
            view.onCreateAudio = parent.onCreateAudio
            view.audioContext = parent.audio
            view.onCreateReminder = parent.onCreateReminder
            view.reminderContext = parent.reminders
            view.sketchPreview = parent.preview
            view.sketchModifiedAt = parent.sketchModifiedAt
            view.isEditable = parent.isEditable && parent.isActive
            view.commandEnabled = parent.isActive && parent.isEditable
            view.commandIsDark = dark
            view.typingAttributes = RichNoteCodec.attributes(dark: dark)
            view.insertionPointColor = RichNoteCodec.ink(dark)
            view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
            view.resizeSketchCards()
            lastMarkdown = markdown
            loading = false
        }

        func textDidChange(_ notification: Notification) {
            guard !loading, let view, let storage = view.textStorage else { return }
            lastMarkdown = RichNoteCodec.encode(storage)
            parent.text = lastMarkdown
            updateSelection()
            view.commandChanged()
            view.needsDisplay = true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !loading else { return }
            updateSelection()
            view?.commandChanged()
        }

        func updateSelection() {
            guard let view, let storage = view.textStorage else { return }
            parent.selectedRange?.wrappedValue = RichNoteCodec.markdownRange(view.selectedRange(), in: storage)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            view?.handleSketchCommand(selector) ?? false
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !loading, let storage = textView.textStorage, let id = parent.audio?.draftID else { return true }
            var allowed = true
            storage.enumerateAttribute(.attachment, in: affectedCharRange) { value, _, _ in
                if let audio = value as? AudioTextAttachment, audio.isDraft, audio.id == id { allowed = false }
            }
            return allowed
        }
    }
}

final class RichNoteTextView: SketchCommandTextView {
    var onOpenSketch: ((UUID) -> Void)?
    var onRenameSketch: ((UUID) -> Void)?
    var sketchPreview: ((UUID) -> Data?)?
    var sketchModifiedAt: ((UUID) -> Date?)?
    var audioContext: AudioNoteEditorContext?
    var reminderContext: ReminderNoteEditorContext?
    private var reminderViews: [ObjectIdentifier: NSHostingView<ReminderInlineRow>] = [:]
    private var reminderAccessibilityActions: [ObjectIdentifier: (complete: ReminderAccessibilityAction, edit: ReminderAccessibilityAction)] = [:]
    private var refreshingReminderViews = false
    private var audioViews: [ObjectIdentifier: NSHostingView<AnyView>] = [:]
    private var audioPresentations: [ObjectIdentifier: AudioOverlayPresentation] = [:]
    private var refreshingAudioViews = false
    private var audioDraftAttachments: [WeakAudioDraftAttachment] = []

    private struct AudioOverlayPresentation: Equatable {
        var audio: NoteAudio?
        var title: String
        var fileURL: URL?
        var isDark: Bool
        var isDraft: Bool
        var draftError: String?
        var expanded: Bool
        var transcriptionBusy: Bool
        var transcriptionError: String?
        var controller: ObjectIdentifier
        var transcriptionController: ObjectIdentifier?
        var transcriptionScope: AudioTranscriptionScope?
        var canTranscribe: Bool
        var canAddTranscript: Bool
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let font = typingAttributes[.font] as? NSFont ?? RichNoteCodec.bodyFont
        let lineHeight = layoutManager?.defaultLineHeight(for: font) ?? ceil(font.ascender - font.descender)
        var caret = rect
        // Paragraph leading belongs between lines, outside the text caret.
        // Staying inside AppKit's rect also preserves its blink invalidation.
        caret.size.height = min(rect.height, lineHeight)
        super.drawInsertionPoint(in: caret, color: color, turnedOn: flag)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeSketchCards()
    }

    override func layout() {
        super.layout()
        resizeSketchCards()
    }

    override func didChangeText() {
        super.didChangeText()
        resizeSketchCards()
    }

    func resizeSketchCards() {
        guard let storage = textStorage, let textContainer else { return }
        let available = min(bounds.width - textContainerInset.width * 2, textContainer.containerSize.width)
            - textContainer.lineFragmentPadding * 2
        guard available > 0 else { return }
        let width = min(SketchCardStyle.maximumWidth, available)
        var changed = false
        // Undo snapshots retain attachment objects. Retire their draft identity
        // too, so Undo can remove a finished recording without reviving a mic
        // row or serializing an internal marker. A space keeps native indices.
        audioDraftAttachments.removeAll { $0.value == nil }
        for reference in audioDraftAttachments {
            if let attachment = reference.value, attachment.id != audioContext?.draftID, !attachment.isRetiredDraft {
                attachment.retireDraft()
                changed = true
            }
        }
        let range = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            if let attachment = value as? SketchTextAttachment,
               let cell = attachment.attachmentCell as? SketchAttachmentCell,
               cell.cardWidth != width {
                cell.cardWidth = width
                changed = true
            }
            if let attachment = value as? ReminderTextAttachment,
               let cell = attachment.attachmentCell as? ReminderAttachmentCell, cell.cardWidth != width {
                cell.cardWidth = width
                changed = true
            }
            if let attachment = value as? AudioTextAttachment,
               !attachment.isRetiredDraft, let cell = attachment.attachmentCell as? AudioAttachmentCell {
                let height = audioContext?.height(id: attachment.id, title: attachment.title, isDraft: attachment.isDraft)
                    ?? (attachment.isDraft ? AudioNoteCardLayout.recordingHeight : AudioNoteCardLayout.baseHeight)
                if cell.cardWidth != width || cell.cardHeight != height {
                    cell.cardWidth = width; cell.cardHeight = height
                    changed = true
                }
            }
        }
        if changed {
            layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        refreshAudioOverlays()
        refreshReminderOverlays()
    }

    func refreshAudioOverlays(updateContent: Bool = false) {
        guard !refreshingAudioViews, let storage = textStorage, let layoutManager, let textContainer else { return }
        refreshingAudioViews = true
        defer { refreshingAudioViews = false }
        var live: Set<ObjectIdentifier> = []
        layoutManager.ensureLayout(for: textContainer)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? AudioTextAttachment,
                      let cell = attachment.attachmentCell as? AudioAttachmentCell else { return }
                let key = ObjectIdentifier(attachment)
                guard let context = audioContext, !attachment.isRetiredDraft,
                      !attachment.isDraft || context.draftID == attachment.id else {
                    if cell.hasLiveOverlay { cell.hasLiveOverlay = false; needsDisplay = true }
                    return
                }
                if attachment.isDraft {
                    if !audioDraftAttachments.contains(where: { $0.value === attachment }) {
                        audioDraftAttachments.append(WeakAudioDraftAttachment(attachment))
                    }
                }
                let presentation = AudioOverlayPresentation(audio: context.recordings[attachment.id],
                    title: attachment.title, fileURL: context.fileURL(attachment.id), isDark: dark,
                    isDraft: attachment.isDraft, draftError: context.draftError,
                    expanded: context.expandedTranscripts.contains(attachment.id),
                    transcriptionBusy: context.transcriptionBusyID == attachment.id,
                    transcriptionError: context.transcriptionErrors[attachment.id],
                    controller: ObjectIdentifier(context.controller),
                    transcriptionController: context.transcription.map(ObjectIdentifier.init),
                    transcriptionScope: context.transcriptionScope,
                    canTranscribe: context.onTranscribe != nil,
                    canAddTranscript: context.onAddTranscriptToNote != nil)
                let host: NSHostingView<AnyView>
                if let existing = audioViews[key] {
                    host = existing
                    if audioPresentations[key] != presentation {
                        host.rootView = audioContent(for: attachment, context: context)
                        audioPresentations[key] = presentation
                    }
                } else {
                    host = NSHostingView(rootView: audioContent(for: attachment, context: context))
                    // NSTextView owns attachment geometry; child content must
                    // not feed intrinsic-size changes back into text layout.
                    host.sizingOptions = []
                    host.wantsLayer = true
                    host.layerContentsRedrawPolicy = .onSetNeedsDisplay
                    audioViews[key] = host
                    audioPresentations[key] = presentation
                    addSubview(host)
                }
                let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
                if host.appearance?.name != appearance { host.appearance = NSAppearance(named: appearance) }
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                if host.frame != frame { host.frame = frame }
                if !cell.hasLiveOverlay { cell.hasLiveOverlay = true; needsDisplay = true }
                live.insert(key)
        }
        for key in Array(audioViews.keys) where !live.contains(key) {
            audioViews.removeValue(forKey: key)?.removeFromSuperview()
            audioPresentations[key] = nil
        }
    }

    private func audioContent(for attachment: AudioTextAttachment, context: AudioNoteEditorContext) -> AnyView {
        // Cache presentation, but resolve actions against the latest editor
        // context so unchanged views never keep stale note/state callbacks.
        var live = context
        live.onRename = { [weak self] in self?.audioContext?.onRename($0) }
        live.onExport = { [weak self] in self?.audioContext?.onExport($0) }
        live.onDelete = { [weak self] in self?.audioContext?.onDelete($0) }
        live.onFinishDraft = { [weak self] in self?.audioContext?.onFinishDraft() }
        live.onDiscardDraft = { [weak self] in self?.audioContext?.onDiscardDraft() }
        live.onTranscribe = context.onTranscribe.map { _ in { [weak self] id in self?.audioContext?.onTranscribe?(id) } }
        live.onToggleTranscript = context.onToggleTranscript.map { _ in { [weak self] id in self?.audioContext?.onToggleTranscript?(id) } }
        live.onAddTranscriptToNote = context.onAddTranscriptToNote.map { _ in
            { [weak self, weak attachment] _ in
                guard let attachment else { return }
                self?.insertTranscript(after: attachment)
            }
        }
        return attachment.isDraft ? AnyView(live.recorder(isDark: dark))
            : AnyView(live.player(id: attachment.id, title: attachment.title, isDark: dark))
    }

    func insertTranscript(after attachment: AudioTextAttachment) {
        guard isEditable, !attachment.isDraft, let storage = textStorage,
              audioContext?.onAddTranscriptToNote != nil,
              let transcript = audioContext?.recordings[attachment.id]?.transcript else { return }
        var anchor: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if (value as? AudioTextAttachment) === attachment { anchor = range }
        }
        guard let anchor,
              let insertion = AudioTranscriptInsertion.make(in: RichNoteCodec.encode(storage), after: attachment.id,
                  transcript: transcript, referenceRange: RichNoteCodec.markdownRange(anchor, in: storage)) else { return }
        let location = NSMaxRange(anchor)
        breakUndoCoalescing()
        insertText(NSAttributedString(string: insertion.plainText, attributes: RichNoteCodec.attributes(dark: dark)),
                   replacementRange: NSRange(location: location, length: 0))
        undoManager?.setActionName("Add transcript to note")
        breakUndoCoalescing()
        typingAttributes = RichNoteCodec.attributes(dark: dark)
        let caret = NSRange(location: location + insertion.caretOffset, length: 0)
        setSelectedRange(caret)
        window?.makeFirstResponder(self)
        scrollRangeToVisible(caret)
    }

    private func refreshReminderOverlays() {
        guard !refreshingReminderViews, let storage = textStorage, let layoutManager, let textContainer else { return }
        refreshingReminderViews = true
        defer { refreshingReminderViews = false }
        var live: Set<ObjectIdentifier> = []
        layoutManager.ensureLayout(for: textContainer)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? ReminderTextAttachment,
                  let cell = attachment.attachmentCell as? ReminderAttachmentCell else { return }
            guard let reminderContext else {
                if cell.hasLiveOverlay { cell.hasLiveOverlay = false; needsDisplay = true }
                return
            }
            let key = ObjectIdentifier(attachment)
            let reminder = reminderContext.reminder(attachment.id)
            let content = ReminderInlineRow(title: reminder?.title ?? attachment.title,
                isCompleted: reminder?.isCompleted ?? false, isAvailable: reminder != nil,
                onToggle: { [weak self] in self?.reminderContext?.onToggle(attachment.id) },
                onEdit: { [weak self] in self?.reminderContext?.onEdit(attachment.id) },
                sourceTitle: reminder?.chapterTitle)
            let host: NSHostingView<ReminderInlineRow>
            if let existing = reminderViews[key] { host = existing; host.rootView = content }
            else { host = NSHostingView(rootView: content); reminderViews[key] = host; addSubview(host) }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            host.frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // The row has a translucent background. Once hosted, the attachment
            // must reserve space without painting a second title underneath it.
            if !cell.hasLiveOverlay { cell.hasLiveOverlay = true; needsDisplay = true }
            let actions: (complete: ReminderAccessibilityAction, edit: ReminderAccessibilityAction)
            if let existing = reminderAccessibilityActions[key] { actions = existing }
            else {
                actions = (ReminderAccessibilityAction(owner: self, role: .checkBox),
                           ReminderAccessibilityAction(owner: self, role: .button))
                reminderAccessibilityActions[key] = actions
            }
            let title = reminder?.title ?? attachment.title
            actions.complete.setAccessibilityLabel((reminder?.isCompleted == true ? "Mark reminder incomplete: " : "Complete reminder: ") + title)
            actions.complete.setAccessibilityValue(NSNumber(value: reminder?.isCompleted == true))
            actions.complete.actionEnabled = reminder != nil
            actions.complete.setAccessibilityEnabled(reminder != nil)
            actions.complete.onPress = { [weak self] in self?.reminderContext?.onToggle(attachment.id) }
            actions.complete.frameProvider = { [weak host] in
                guard let host, let window = host.window else { return .zero }
                let local = NSRect(x: 12, y: (host.bounds.height - 36) / 2, width: 28, height: 36)
                return window.convertToScreen(host.convert(local, to: nil))
            }
            actions.edit.setAccessibilityLabel("Edit reminder: " + title)
            actions.edit.actionEnabled = reminder != nil
            actions.edit.setAccessibilityEnabled(reminder != nil)
            actions.edit.onPress = { [weak self] in self?.reminderContext?.onEdit(attachment.id) }
            actions.edit.frameProvider = { [weak host] in
                guard let host, let window = host.window else { return .zero }
                let local = NSRect(x: host.bounds.width - 40, y: (host.bounds.height - 36) / 2, width: 28, height: 36)
                return window.convertToScreen(host.convert(local, to: nil))
            }
            live.insert(key)
        }
        for key in Array(reminderViews.keys) where !live.contains(key) {
            reminderViews.removeValue(forKey: key)?.removeFromSuperview()
            reminderAccessibilityActions.removeValue(forKey: key)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        // NSTextView normally exposes attachment text as a leaf and omits its
        // hosted NSViews. Keep native text semantics while exposing real row
        // buttons to VoiceOver and other accessibility clients.
        var children = super.accessibilityChildren() ?? []
        for (key, host) in reminderViews.sorted(by: { $0.value.frame.minY < $1.value.frame.minY }) where !host.isHiddenOrHasHiddenAncestor {
            guard let actions = reminderAccessibilityActions[key] else { continue }
            children.append(actions.complete)
            if actions.edit.actionEnabled { children.append(actions.edit) }
        }
        return children.isEmpty ? nil : children
    }

    override func commandCandidate() -> NSRange? {
        guard let storage = textStorage, let range = SketchReference.commandSuggestionRange(in: string, selection: selectedRange())
                ?? AudioReference.commandSuggestionRange(in: string, selection: selectedRange())
                ?? ReminderReference.commandSuggestionRange(in: string, selection: selectedRange()),
              storage.attribute(.noteCode, at: range.location, effectiveRange: nil) as? Bool != true else { return nil }
        return RichNoteCodec.markdownRange(range, in: storage)
    }

    override func handleSketchCommand(_ selector: Selector) -> Bool {
        let selection = selectedRange()
        if selector == #selector(NSResponder.insertNewline(_:)), selection.length == 1,
           selection.location < (textStorage?.length ?? 0),
           let card = textStorage?.attribute(.attachment, at: selection.location, effectiveRange: nil) as? SketchTextAttachment,
           let onOpenSketch { onOpenSketch(card.id); return true }
        if selector == #selector(NSResponder.insertNewline(_:)), selection.length == 1,
           selection.location < (textStorage?.length ?? 0),
           let attachment = textStorage?.attribute(.attachment, at: selection.location, effectiveRange: nil) as? AudioTextAttachment,
           !attachment.isDraft, let context = audioContext, let url = context.fileURL(attachment.id) {
            try? context.controller.play(id: attachment.id, url: url)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)), selection.length == 1,
           selection.location < (textStorage?.length ?? 0),
           let attachment = textStorage?.attribute(.attachment, at: selection.location, effectiveRange: nil) as? ReminderTextAttachment,
           let context = reminderContext { context.onEdit(attachment.id); return true }
        return super.handleSketchCommand(selector)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (attachment, frame) = sketchCard(at: point) {
            if SketchCardLayout(frame: frame).options.contains(point) {
                let menu = sketchMenu(for: attachment)
                menu.popUp(positioning: nil, at: NSPoint(x: frame.maxX - 12, y: frame.maxY - 8), in: self)
            } else {
                onOpenSketch?(attachment.id)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let (attachment, _) = sketchCard(at: convert(event.locationInWindow, from: nil)) {
            return sketchMenu(for: attachment)
        }
        return super.menu(for: event)
    }

    private func sketchCard(at point: NSPoint) -> (SketchTextAttachment, NSRect)? {
        guard let layoutManager, let textContainer else { return nil }
        let index = layoutManager.characterIndex(for: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y), in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        if index < (textStorage?.length ?? 0), let attachment = textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? SketchTextAttachment {
            let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyph, in: textContainer).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            if rect.contains(point) { return (attachment, rect) }
        }
        return nil
    }

    private func sketchMenu(for attachment: SketchTextAttachment) -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Sketch", action: #selector(openSketchFromMenu(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = attachment.id
        menu.addItem(open)
        if onRenameSketch != nil {
            let rename = NSMenuItem(title: "Rename…", action: #selector(renameSketchFromMenu(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = attachment.id
            menu.addItem(rename)
        }
        return menu
    }

    @objc private func openSketchFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onOpenSketch?(id) }
    }

    @objc private func renameSketchFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onRenameSketch?(id) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage, let layoutManager, let textContainer else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value is SketchTextAttachment else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    var dark = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("A thought worth keeping…" as NSString).draw(
                at: textContainerOrigin,
                withAttributes: [.font: RichNoteCodec.bodyFont,
                                 .foregroundColor: RichNoteCodec.ink(dark).withAlphaComponent(0.38)])
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command {
            switch key {
            case "b": toggleTrait(.boldFontMask); return true
            case "i": toggleTrait(.italicFontMask); return true
            case "u": toggleAttribute(.underlineStyle); return true
            case "k": editLink(); return true
            default: break
            }
        } else if modifiers == [.command, .shift], key == "x" {
            toggleAttribute(.strikethroughStyle); return true
        } else if modifiers == [.command, .option] {
            switch key {
            case "0": formatParagraph(heading: 0); return true
            case "1", "2", "3": formatParagraph(heading: Int(key) ?? 1); return true
            case "7": toggleList(numbered: true); return true
            case "8": toggleList(numbered: false); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func transform(_ change: (NSMutableAttributedString) -> Void) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        change(replacement)
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: replacement.length))
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let font = (selectedRange().length > 0 ? textStorage?.attribute(.font, at: selectedRange().location, effectiveRange: nil) : typingAttributes[.font]) as? NSFont ?? RichNoteCodec.bodyFont
        let remove = NSFontManager.shared.traits(of: font).contains(trait)
        func converted(_ font: NSFont) -> NSFont {
            remove ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait)
        }
        if selectedRange().length == 0 {
            typingAttributes[.font] = converted(font)
        } else {
            transform { value in
                value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { font, range, _ in
                    value.addAttribute(.font, value: converted(font as? NSFont ?? RichNoteCodec.bodyFont), range: range)
                }
            }
        }
    }

    private func toggleAttribute(_ key: NSAttributedString.Key) {
        let current = selectedRange().length > 0 ? textStorage?.attribute(key, at: selectedRange().location, effectiveRange: nil) : typingAttributes[key]
        let enabled = (current as? Int ?? 0) != 0
        if selectedRange().length == 0 {
            typingAttributes[key] = enabled ? 0 : 1
        } else {
            transform { value in
                value.addAttribute(key, value: enabled ? 0 : 1, range: NSRange(location: 0, length: value.length))
            }
        }
    }

    private func editLink() {
        guard selectedRange().length > 0, let window else { return }
        let selection = selectedRange()
        let alert = NSAlert()
        alert.messageText = "Add a link"
        alert.informativeText = "Enter the destination for the selected text. Leave it empty to remove the link."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        field.placeholderString = "https://example.com"
        if let existing = textStorage?.attribute(.link, at: selection.location, effectiveRange: nil) {
            field.stringValue = String(describing: existing)
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.setSelectedRange(selection)
            self.transform { value in
                let range = NSRange(location: 0, length: value.length)
                let destination = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if destination.isEmpty { value.removeAttribute(.link, range: range) }
                else { value.addAttribute(.link, value: destination, range: range) }
            }
            window.makeFirstResponder(self)
        }
    }

    private func formatParagraph(heading: Int) {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        if range.length == 0 {
            typingAttributes[.noteHeading] = heading
            typingAttributes[.font] = RichNoteCodec.font(heading: heading)
            return
        }
        setSelectedRange(range)
        transform { value in
            let all = NSRange(location: 0, length: value.length)
            value.addAttribute(.noteHeading, value: heading, range: all)
            value.addAttribute(.font, value: RichNoteCodec.font(heading: heading), range: all)
        }
    }

    private func toggleList(numbered: Bool) {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        guard let storage = textStorage else { return }
        let value = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let ns = value.string as NSString
        var lines: [NSRange] = []
        var index = 0
        while index < ns.length {
            let line = ns.lineRange(for: NSRange(location: index, length: 0))
            lines.append(line); index = NSMaxRange(line)
        }
        if lines.isEmpty { lines = [NSRange(location: 0, length: 0)] }
        for (number, line) in lines.enumerated().reversed() {
            let content = ns.substring(with: line)
            let marker = content.range(of: #"^(• |\d+\. )"#, options: .regularExpression)
            if let marker {
                value.deleteCharacters(in: NSRange(location: line.location, length: content[marker].utf16.count))
            } else {
                value.insert(NSAttributedString(string: numbered ? "\(number + 1). " : "• ", attributes: RichNoteCodec.attributes(dark: dark)), at: line.location)
            }
        }
        insertText(value, replacementRange: range)
    }

    override func insertNewline(_ sender: Any?) {
        if handleSketchCommand(#selector(NSResponder.insertNewline(_:))) { return }
        let ns = string as NSString
        let selected = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: selected.location, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        if selected.length == 0, selected.location == lineRange.location + line.utf16.count,
           let match = ListLine.match(line.replacingOccurrences(of: "• ", with: "- ", options: .anchored)) {
            if match.content.isEmpty {
                insertText("", replacementRange: NSRange(location: lineRange.location, length: line.utf16.count))
                typingAttributes = RichNoteCodec.attributes(dark: dark)
            } else {
                let marker = line.hasPrefix("• ") ? "• " : match.nextMarker
                insertText("\n" + match.indent + marker, replacementRange: selected)
            }
            return
        }
        super.insertNewline(sender)
        typingAttributes = RichNoteCodec.attributes(dark: dark)
    }

    private static let sketchPasteboardType = NSPasteboard.PasteboardType("com.olly.kodi.sketch-markdown")

    private var selectedSketchContent: NSAttributedString? {
        guard selectedRange().length > 0, let storage = textStorage else { return nil }
        let value = storage.attributedSubstring(from: selectedRange())
        var containsSketch = false
        value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, _, _ in
            if attachment is SketchTextAttachment || attachment is AudioTextAttachment || attachment is ReminderTextAttachment { containsSketch = true }
        }
        return containsSketch ? value : nil
    }

    override func copy(_ sender: Any?) {
        guard let value = selectedSketchContent else { super.copy(sender); return }
        let markdown = RichNoteCodec.encode(value)
        AudioNoteClipboard.retain(markdown, context: audioContext)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        NSPasteboard.general.setString(markdown, forType: Self.sketchPasteboardType)
    }

    override func cut(_ sender: Any?) {
        guard selectedSketchContent != nil else { super.cut(sender); return }
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }

    // Keep pasted formatting within the same portable vocabulary as typing.
    override func paste(_ sender: Any?) {
        defer { suppressPastedCommand() }
        if let markdown = NSPasteboard.general.string(forType: Self.sketchPasteboardType) {
            insertText(RichNoteCodec.decode(markdown, dark: dark, preview: sketchPreview, sketchModifiedAt: sketchModifiedAt, audioDraftID: audioContext?.draftID), replacementRange: selectedRange())
        } else if let raw = NSPasteboard.general.string(forType: .string) {
            insertText(NSAttributedString(string: raw, attributes: typingAttributes), replacementRange: selectedRange())
        }
    }
}

private extension NSAttributedString.Key {
    static let noteHeading = NSAttributedString.Key("KodiNoteHeading")
    static let noteCode = NSAttributedString.Key("KodiNoteCode")
}

enum RichNoteCodec {
    static let bodyFont = NSFont.systemFont(ofSize: 16)
    static func ink(_ dark: Bool) -> NSColor {
        dark ? NSColor(red: 0.84, green: 0.89, blue: 0.85, alpha: 1) : NSColor(red: 0.32, green: 0.40, blue: 0.31, alpha: 1)
    }
    static func font(heading: Int) -> NSFont {
        heading == 0 ? bodyFont : NSFont(name: "Georgia", size: CGFloat(28 - heading * 2)) ?? .systemFont(ofSize: 24)
    }
    static func attributes(dark: Bool, heading: Int = 0) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 10
        return [.font: font(heading: heading), .foregroundColor: ink(dark), .paragraphStyle: paragraph, .noteHeading: heading]
    }

    static func sourceOnlyReason(_ markdown: String) -> String? {
        let checks = [
            (#"(?m)^\s*(```|~~~)"#, "code blocks"),
            (#"(?m)^.*\|.*\n\s*\|?\s*:?-+"#, "a table"),
            (#"(?m)^\s*[-*+] \[[ xX]\]"#, "a checklist"),
            (#"(?m)^[\t ]{2,}\S|^>"#, "indented text or block quotes"),
            (#"(?m)^\s*(---+|___+|\*\*\*+|===+)\s*$"#, "a thematic break or setext heading"),
        ]
        return checks.first { markdown.range(of: $0.0, options: .regularExpression) != nil }?.1
    }

    static func markdownRange(_ selection: NSRange, in value: NSAttributedString) -> NSRange {
        let start = min(selection.location, value.length)
        let end = min(NSMaxRange(selection), value.length)
        let before = encode(value.attributedSubstring(from: NSRange(location: 0, length: start))).utf16.count
        let through = encode(value.attributedSubstring(from: NSRange(location: 0, length: end))).utf16.count
        return NSRange(location: before, length: max(0, through - before))
    }

    static func richRange(_ selection: NSRange, in value: NSAttributedString) -> NSRange {
        var start = value.length
        var end = value.length
        var index = 0
        let ns = value.string as NSString
        while index <= value.length {
            let offset = encode(value.attributedSubstring(from: NSRange(location: 0, length: index))).utf16.count
            if offset >= selection.location, start == value.length { start = index }
            if offset >= NSMaxRange(selection) { end = index; break }
            if index == value.length { break }
            index = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: index))
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    static func decode(_ markdown: String, dark: Bool, preview: ((UUID) -> Data?)? = nil, sketchModifiedAt: ((UUID) -> Date?)? = nil, audioDraftID: UUID? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = markdown.components(separatedBy: "\n")
        let sketchOffsets = Set(SketchReference.references(in: markdown).map { $0.range.location })
        let audioOffsets = Set(AudioReference.references(in: markdown).map { $0.range.location })
        let reminderOffsets = Set(ReminderReference.references(in: markdown).map { $0.range.location })
        var lineOffset = 0
        for (index, original) in lines.enumerated() {
            defer { lineOffset += original.utf16.count + 1 }
            if reminderOffsets.contains(lineOffset), let (id, title) = ReminderReference.parseLine(original) {
                result.append(NSAttributedString(attachment: ReminderTextAttachment(id: id, title: title)))
                if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes(dark: dark))) }
                continue
            }
            if audioOffsets.contains(lineOffset), let (id, title) = AudioReference.parseLine(original) {
                result.append(NSAttributedString(attachment: AudioTextAttachment(id: id, title: title)))
                if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes(dark: dark))) }
                continue
            }
            if let id = AudioDraftReference.parse(original), id == audioDraftID {
                result.append(NSAttributedString(attachment: AudioTextAttachment(id: id, title: "Recording", isDraft: true)))
                if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes(dark: dark))) }
                continue
            }
            if sketchOffsets.contains(lineOffset), let (id, title) = SketchReference.parseLine(original) {
                let attachment = SketchTextAttachment(id: id, title: title, preview: preview?(id), modifiedAt: sketchModifiedAt?(id), isDark: dark)
                result.append(NSAttributedString(attachment: attachment))
                if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes(dark: dark))) }
                continue
            }
            var line = original
            var heading = 0
            if let prefix = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                heading = line[prefix].count - 1
                line.removeSubrange(prefix)
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                line = "• " + line.dropFirst(2)
            }
            let base = attributes(dark: dark, heading: heading)
            // Sentinels let Markdown parse across underline boundaries, so nested
            // bold/italic/link spans keep their meaning.
            let marked = line.replacingOccurrences(of: "<u>", with: "\u{E000}")
                .replacingOccurrences(of: "</u>", with: "\u{E001}")
            let parsed = try? AttributedString(markdown: marked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            var underlined = false
            if let parsed {
                for run in parsed.runs {
                    var attrs = base
                    let intent = run.inlinePresentationIntent ?? []
                    var font = Self.font(heading: heading)
                    if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 14, weight: .regular); attrs[.noteCode] = true }
                    attrs[.font] = font
                    if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = 1 }
                    if let link = run.link { attrs[.link] = link }
                    for character in parsed[run.range].characters {
                        if character == "\u{E000}" { underlined = true; continue }
                        if character == "\u{E001}" { underlined = false; continue }
                        if underlined { attrs[.underlineStyle] = 1 } else { attrs.removeValue(forKey: .underlineStyle) }
                        result.append(NSAttributedString(string: String(character), attributes: attrs))
                    }
                }
            } else { result.append(NSAttributedString(string: line, attributes: base)) }
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        return result
    }

    private struct Mark: Equatable {
        let open: String
        let close: String
    }

    private static func encodeInline(_ value: NSAttributedString) -> String {
        struct Token { var text: String; var marks: [Mark] }
        var tokens: [Token] = []
        let ns = value.string as NSString
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? SketchTextAttachment {
                tokens.append(Token(text: SketchReference.markdown(id: attachment.id, title: attachment.title), marks: []))
                return
            }
            if let attachment = attrs[.attachment] as? ReminderTextAttachment {
                tokens.append(Token(text: ReminderReference.markdown(id: attachment.id, title: attachment.title), marks: []))
                return
            }
            if let attachment = attrs[.attachment] as? AudioTextAttachment {
                tokens.append(Token(text: attachment.markdown, marks: []))
                return
            }
            var marks: [Mark] = []
            if let link = attrs[.link] {
                let destination = String(describing: link).replacingOccurrences(of: " ", with: "%20")
                    .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                marks.append(Mark(open: "[", close: "](" + destination + ")"))
            }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { marks.append(Mark(open: "<u>", close: "</u>")) }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { marks.append(Mark(open: "~~", close: "~~")) }
            let traits = NSFontManager.shared.traits(of: attrs[.font] as? NSFont ?? bodyFont)
            if traits.contains(.boldFontMask) { marks.append(Mark(open: "**", close: "**")) }
            if traits.contains(.italicFontMask) { marks.append(Mark(open: "*", close: "*")) }
            let raw = ns.substring(with: range)
            if attrs[.noteCode] as? Bool == true {
                let longest = raw.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: longest + 1)
                tokens.append(Token(text: fence + " " + raw + " " + fence, marks: marks))
            } else {
                for character in raw {
                    let escaped = "\\*_[]`~<>#".contains(character) ? "\\" + String(character) : String(character)
                    tokens.append(Token(text: escaped, marks: marks))
                }
            }
        }
        // Keep spaces inside shared spans, and outside newly opened/closed spans.
        for index in tokens.indices where tokens[index].text.allSatisfy(\.isWhitespace) {
            let before = tokens[..<index].last(where: { !$0.text.allSatisfy(\.isWhitespace) })?.marks ?? []
            let after = tokens[(index + 1)...].first(where: { !$0.text.allSatisfy(\.isWhitespace) })?.marks ?? []
            tokens[index].marks = tokens[index].marks.filter { before.contains($0) && after.contains($0) }
        }
        var output = ""
        var open: [Mark] = []
        for token in tokens {
            let wanted = open.filter { token.marks.contains($0) }
                + token.marks.filter { !open.contains($0) }
            let common = zip(open, wanted).prefix(while: { $0 == $1 }).count
            for mark in open.dropFirst(common).reversed() { output += mark.close }
            for mark in wanted.dropFirst(common) { output += mark.open }
            output += token.text
            open = wanted
        }
        for mark in open.reversed() { output += mark.close }
        return output
    }

    static func encode(_ value: NSAttributedString) -> String {
        let ns = value.string as NSString
        var output = ""
        var index = 0
        while index < ns.length {
            let line = ns.lineRange(for: NSRange(location: index, length: 0))
            var content = line
            let newline = ns.substring(with: line).hasSuffix("\n")
            if newline { content.length -= 1 }
            let heading = value.attribute(.noteHeading, at: index, effectiveRange: nil) as? Int ?? 0
            if heading > 0 { output += String(repeating: "#", count: heading) + " " }
            let plain = ns.substring(with: content)
            if plain.hasPrefix("• ") {
                output += "- "; content.location += 2; content.length -= 2
            } else if let marker = plain.range(of: #"^\d+\. "#, options: .regularExpression) {
                let prefix = String(plain[marker]); output += prefix
                content.location += prefix.utf16.count; content.length -= prefix.utf16.count
            }
            output += encodeInline(value.attributedSubstring(from: content))
            if newline { output += "\n" }
            index = NSMaxRange(line)
        }
        return output
    }
}

/// NSTextView treats hosted SwiftUI content as attachment text in its native
/// accessibility tree. Cache explicit actions so assistive clients can operate
/// the same controls that are visible and clickable in the row.
final class ReminderAccessibilityAction: NSAccessibilityElement {
    weak var owner: NSView?
    var actionEnabled = true
    var onPress: (() -> Void)?
    var frameProvider: (() -> NSRect)?

    init(owner: NSView, role: NSAccessibility.Role) {
        self.owner = owner
        super.init()
        setAccessibilityRole(role)
    }

    override func accessibilityParent() -> Any? { owner }
    override func accessibilityFrame() -> NSRect { frameProvider?() ?? .zero }
    override func accessibilityPerformPress() -> Bool {
        guard actionEnabled, let onPress else { return false }
        onPress()
        return true
    }
}

/// Resolve live reminder state without coupling the native editor to AppModel.
struct ReminderNoteEditorContext {
    var reminder: (UUID) -> ResearchReminder?
    var onToggle: (UUID) -> Void
    var onEdit: (UUID) -> Void
}

/// Used by both the writing surface and Markdown preview.
struct ReminderInlineRow: View {
    let title: String
    let isCompleted: Bool
    var isAvailable = true
    var onToggle: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var sourceTitle: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ReminderPopoverPalette { .init(isDark: colorScheme == .dark) }

    var body: some View {
        HStack(spacing: 12) {
            Button { onToggle?() } label: {
                Image(systemName: isCompleted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(palette.accent)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable || onToggle == nil)
            .accessibilityLabel((isCompleted ? "Mark reminder incomplete: " : "Complete reminder: ") + title)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .strikethrough(isCompleted)
                    .foregroundStyle(isCompleted ? palette.muted : palette.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(isAvailable ? (sourceTitle ?? "Research later") : "Reminder unavailable")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let onEdit, isAvailable {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit reminder")
                .accessibilityLabel("Edit reminder: " + title)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(palette.field, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Research reminder: " + title)
    }
}

final class ReminderTextAttachment: NSTextAttachment {
    let id: UUID
    let title: String
    init(id: UUID, title: String) {
        self.id = id; self.title = title
        super.init(data: nil, ofType: nil)
        attachmentCell = ReminderAttachmentCell(title: title)
    }
    required init?(coder: NSCoder) { return nil }
}

final class ReminderAttachmentCell: NSTextAttachmentCell {
    var cardWidth: CGFloat = 280
    var hasLiveOverlay = false
    init(title: String) { super.init(textCell: title) }
    required init(coder: NSCoder) { fatalError("Reminder rows are decoded from Markdown") }
    override func cellSize() -> NSSize { NSSize(width: cardWidth, height: 64) }
    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        guard !hasLiveOverlay else { return }
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9).fill()
        (stringValue as NSString).draw(in: frame.insetBy(dx: 14, dy: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
    }
}

/// Native controls are hosted over this attachment's glyph rectangle.
final class AudioTextAttachment: NSTextAttachment {
    let id: UUID
    let title: String
    let isDraft: Bool
    private(set) var isRetiredDraft = false
    var markdown: String {
        isRetiredDraft ? " " : isDraft ? AudioDraftReference.marker(id) : AudioReference.markdown(id: id, title: title)
    }
    init(id: UUID, title: String, isDraft: Bool = false) {
        self.id = id; self.title = title; self.isDraft = isDraft
        super.init(data: nil, ofType: nil)
        let cell = AudioAttachmentCell(title: title)
        cell.cardHeight = isDraft ? AudioNoteCardLayout.recordingHeight : AudioNoteCardLayout.baseHeight
        attachmentCell = cell
    }
    required init?(coder: NSCoder) { return nil }
    func retireDraft() {
        guard isDraft else { return }
        isRetiredDraft = true
        if let cell = attachmentCell as? AudioAttachmentCell { cell.isRetiredDraft = true }
    }
}

private final class WeakAudioDraftAttachment {
    weak var value: AudioTextAttachment?
    init(_ value: AudioTextAttachment) { self.value = value }
}

final class AudioAttachmentCell: NSTextAttachmentCell {
    var cardWidth: CGFloat = 280
    var cardHeight: CGFloat = AudioNoteCardLayout.baseHeight
    var isRetiredDraft = false
    var hasLiveOverlay = false
    init(title: String) { super.init(textCell: title) }
    required init(coder: NSCoder) { fatalError("Audio cards are decoded from Markdown") }
    override func cellSize() -> NSSize { isRetiredDraft ? NSSize(width: 4, height: 20) : NSSize(width: cardWidth, height: cardHeight) }
    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        guard !isRetiredDraft, !hasLiveOverlay else { return }
        // The hosted SwiftUI row supplies real accessible buttons and a slider.
        // Keep a readable fallback for codecs/tests without an editor context.
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
        ("Audio note" as NSString).draw(at: NSPoint(x: frame.minX + 12, y: frame.minY + 14),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

/// The attachment carries identity independently of its rendered image.
final class SketchTextAttachment: NSTextAttachment {
    let id: UUID
    let title: String
    init(id: UUID, title: String, preview: Data?, modifiedAt: Date? = nil, isDark: Bool = false) {
        self.id = id; self.title = title
        super.init(data: nil, ofType: nil)
        attachmentCell = SketchAttachmentCell(title: title, preview: preview, modifiedAt: modifiedAt, isDark: isDark)
    }
    required init?(coder: NSCoder) { return nil }
}

/// Shared appearance for editable attachments, Markdown previews, and the sketch browser.
enum SketchCardStyle {
    static let cornerRadius: CGFloat = 16
    static let footerHeight: CGFloat = 64
    static let maximumWidth: CGFloat = 560
    static let previewAspectRatio: CGFloat = 1.75
    static let minimumPreviewHeight: CGFloat = 120

    struct Palette {
        let paper: NSColor
        let surface: NSColor
        let border: NSColor
        let ink: NSColor
        let muted: NSColor
        let accent: NSColor
        let actionInk: NSColor
        let actionBorder: NSColor
        let iconSurface: NSColor
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static func palette(dark: Bool) -> Palette {
        Palette(paper: color(0xEEEEE4),
                surface: color(dark ? 0x252E27 : 0xF4F5EC),
                border: color(dark ? 0x465046 : 0xD3D9CB),
                ink: color(dark ? 0xE3E8E1 : 0x26372D),
                muted: color(dark ? 0xA6AFA4 : 0x63705F),
                accent: color(0xFFD645),
                actionInk: color(dark ? 0xFFD645 : 0x695500),
                actionBorder: color(dark ? 0x6D7046 : 0xB8A24A),
                iconSurface: color(dark ? 0x354137 : 0xE7E8D6))
    }

    static func previewHeight(for width: CGFloat) -> CGFloat {
        max(minimumPreviewHeight, width / previewAspectRatio)
    }

    static func editedLabel(_ modifiedAt: Date?, now: Date = Date()) -> String {
        guard let modifiedAt else { return "Sketch" }
        if now.timeIntervalSince(modifiedAt) < 60 { return "Edited just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Edited " + formatter.localizedString(for: modifiedAt, relativeTo: now)
    }
}

/// Attachment drawing and pointer hit testing use the same footer geometry.
struct SketchCardLayout {
    let preview: NSRect
    let footer: NSRect
    let icon: NSRect
    let title: NSRect
    let subtitle: NSRect
    let open: NSRect
    let options: NSRect

    init(frame: NSRect) {
        let previewHeight = max(0, frame.height - SketchCardStyle.footerHeight)
        preview = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: previewHeight)
        footer = NSRect(x: frame.minX, y: preview.maxY, width: frame.width, height: SketchCardStyle.footerHeight)
        let showIcon = frame.width >= 280
        icon = NSRect(x: frame.minX + 14, y: footer.minY + 14, width: showIcon ? 32 : 0, height: 36)
        options = NSRect(x: frame.maxX - 40, y: footer.minY + 17, width: 28, height: 30)
        let openWidth: CGFloat = frame.width >= 280 ? 76 : 32
        open = NSRect(x: options.minX - openWidth - 8, y: footer.minY + 16, width: openWidth, height: 32)
        let textX = showIcon ? icon.maxX + 11 : frame.minX + 14
        title = NSRect(x: textX, y: footer.minY + 12, width: max(0, open.minX - textX - 10), height: 20)
        subtitle = NSRect(x: textX, y: footer.minY + 34, width: title.width, height: 17)
    }
}

final class SketchAttachmentCell: NSTextAttachmentCell {
    let sketchTitle: String
    var preview: Data? {
        didSet { if oldValue != preview { previewImage = preview.flatMap(NSImage.init(data:)) } }
    }
    private var previewImage: NSImage?
    var modifiedAt: Date?
    var isDark: Bool
    var cardWidth: CGFloat = 320

    init(title: String, preview: Data?, modifiedAt: Date? = nil, isDark: Bool = false) {
        self.sketchTitle = title; self.preview = preview
        self.previewImage = preview.flatMap(NSImage.init(data:))
        self.modifiedAt = modifiedAt; self.isDark = isDark
        super.init(imageCell: nil)
        self.title = title
    }
    required init(coder: NSCoder) { fatalError("Sketch cards are decoded from Markdown") }

    override func cellSize() -> NSSize {
        NSSize(width: cardWidth, height: SketchCardStyle.previewHeight(for: cardWidth) + SketchCardStyle.footerHeight)
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        let palette = SketchCardStyle.palette(dark: isDark)
        let layout = SketchCardLayout(frame: frame)
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: SketchCardStyle.cornerRadius, yRadius: SketchCardStyle.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        outline.addClip()
        palette.surface.setFill()
        frame.fill()
        palette.paper.setFill()
        layout.preview.fill()

        let imageRect = layout.preview.insetBy(dx: 20, dy: 18)
        if let image = previewImage, image.size.width > 0, image.size.height > 0 {
            let ratio = min(imageRect.width / image.size.width, imageRect.height / image.size.height)
            let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            drawSymbol("scribble", in: NSRect(x: imageRect.midX - 12, y: imageRect.midY - 26, width: 24, height: 24), color: SketchCardStyle.color(0x63705F), size: 22)
            drawText("Preview unavailable", in: NSRect(x: imageRect.minX, y: imageRect.midY + 6, width: imageRect.width, height: 20), font: .systemFont(ofSize: 12), color: SketchCardStyle.color(0x63705F), alignment: .center)
        }

        let expand = NSRect(x: layout.preview.maxX - 38, y: layout.preview.maxY - 38, width: 26, height: 26)
        SketchCardStyle.color(0xE0E5D9).setFill()
        NSBezierPath(roundedRect: expand, xRadius: 6, yRadius: 6).fill()
        drawSymbol("arrow.up.left.and.arrow.down.right", in: expand.insetBy(dx: 6, dy: 6), color: SketchCardStyle.color(0x405249), size: 12)

        if layout.icon.width > 0 {
            palette.iconSurface.setFill()
            NSBezierPath(roundedRect: layout.icon, xRadius: 8, yRadius: 8).fill()
            drawSymbol("pencil", in: layout.icon.insetBy(dx: 8, dy: 10), color: palette.actionInk, size: 16)
        }
        drawText(sketchTitle, in: layout.title, font: .systemFont(ofSize: 13, weight: .semibold), color: palette.ink)
        drawText(SketchCardStyle.editedLabel(modifiedAt), in: layout.subtitle, font: .systemFont(ofSize: 11), color: palette.muted)

        palette.actionBorder.setStroke()
        let open = NSBezierPath(roundedRect: layout.open.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        open.lineWidth = 1
        open.stroke()
        if layout.open.width > 40 {
            drawText("Open", in: NSRect(x: layout.open.minX + 11, y: layout.open.minY + 7, width: 34, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: palette.actionInk)
            drawSymbol("arrow.up.right", in: NSRect(x: layout.open.maxX - 25, y: layout.open.minY + 10, width: 12, height: 12), color: palette.actionInk, size: 12)
        } else {
            drawSymbol("arrow.up.right", in: layout.open.insetBy(dx: 10, dy: 10), color: palette.actionInk, size: 12)
        }
        drawSymbol("ellipsis", in: layout.options.insetBy(dx: 6, dy: 7), color: palette.muted, size: 15)
        palette.border.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor, size: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let fitted = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                             width: fitted.width, height: fitted.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
