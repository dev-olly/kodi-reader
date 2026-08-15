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

    func makeNSView(context: Context) -> NSView {
        let host = EditorHostView()
        host.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textView = NSTextView()
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

        scroll.documentView = textView

        let placeholderLabel = NSTextField(labelWithString: placeholder ?? "")
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.font = textView.font
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.isBezeled = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.isHidden = !(text.isEmpty && !(placeholder?.isEmpty ?? true))

        host.addSubview(scroll)
        host.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: Self.containerInset.width
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: host.trailingAnchor,
                constant: -Self.containerInset.width
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: host.topAnchor,
                constant: Self.containerInset.height
            ),
        ])

        context.coordinator.textView = textView
        context.coordinator.placeholderLabel = placeholderLabel
        context.coordinator.parent = self
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable

        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let max = (text as NSString).length
            let location = min(selected.location, max)
            let length = min(selected.length, max - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
        }

        if textView.selectedRange() != selectedRange {
            let max = (text as NSString).length
            let location = min(selectedRange.location, max)
            let length = min(selectedRange.length, max - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
        }

        context.coordinator.refreshPlaceholder()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        weak var textView: NSTextView?
        weak var placeholderLabel: NSTextField?

        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
        }

        func refreshPlaceholder() {
            guard let placeholderLabel else { return }
            let placeholder = parent.placeholder ?? ""
            placeholderLabel.stringValue = placeholder
            placeholderLabel.isHidden = !(parent.text.isEmpty && !placeholder.isEmpty)
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

/// Thin host so the placeholder can sit above the scroll view at the text inset.
private final class EditorHostView: NSView {
    override var isFlipped: Bool { true }
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
