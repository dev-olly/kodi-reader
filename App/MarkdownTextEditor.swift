import AppKit
import SwiftUI

/// Source editor for advanced Markdown that cannot be safely round-tripped.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var isEditable: Bool = true
    var placeholder: String? = nil

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

        context.coordinator.textView = textView
        context.coordinator.parent = self
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable

        if textView.string != text {
            textView.string = text
        }

        if textView.selectedRange() != selectedRange {
            applySelection(selectedRange, to: textView)
        }

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

        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
        }

        func refreshPlaceholder() {
            guard let textView else { return }
            textView.placeholderString = parent.placeholder ?? ""
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.selectedRange = textView.selectedRange()
            refreshPlaceholder()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.selectedRange = textView.selectedRange()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            return insertListAwareNewline(in: textView)
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

/// Draws the placeholder in the extra line fragment so it shares the caret’s line.
fileprivate final class NoteTextView: NSTextView {
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        let view = RichNoteTextView()
        view.isRichText = true
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
        context.coordinator.view = view
        context.coordinator.load(text, dark: isDark)
        if autofocus {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
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
        init(_ parent: RichNoteEditor) { self.parent = parent }

        func load(_ markdown: String, dark: Bool) {
            guard let view else { return }
            loading = true
            let selection = view.selectedRange()
            view.dark = dark
            view.textStorage?.setAttributedString(RichNoteCodec.decode(markdown, dark: dark))
            view.typingAttributes = RichNoteCodec.attributes(dark: dark)
            view.insertionPointColor = RichNoteCodec.ink(dark)
            view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
            lastMarkdown = markdown
            loading = false
        }

        func textDidChange(_ notification: Notification) {
            guard !loading, let view, let storage = view.textStorage else { return }
            lastMarkdown = RichNoteCodec.encode(storage)
            parent.text = lastMarkdown
            view.needsDisplay = true
        }
    }
}

final class RichNoteTextView: NSTextView {
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

    // Keep pasted formatting within the same portable vocabulary as typing.
    override func paste(_ sender: Any?) {
        if let raw = NSPasteboard.general.string(forType: .string) {
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
            (#"(?m)^\s{2,}\S|^>"#, "indented text or block quotes"),
            (#"(?m)^\s*(---+|___+|\*\*\*+|===+)\s*$"#, "a thematic break or setext heading"),
        ]
        return checks.first { markdown.range(of: $0.0, options: .regularExpression) != nil }?.1
    }

    static func decode(_ markdown: String, dark: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = markdown.components(separatedBy: "\n")
        for (index, original) in lines.enumerated() {
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
