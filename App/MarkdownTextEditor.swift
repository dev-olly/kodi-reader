import AppKit
import SwiftUI

/// Plain-text editor that exposes the selected range so the markdown toolbar
/// can wrap or prefix the selection without becoming a rich-text store.
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
