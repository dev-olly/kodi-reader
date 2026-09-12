import AppKit
import SwiftUI

@main struct NoteEditorTests {
    static func main() {
        _ = NSApplication.shared
        let samples = [
            "A thought worth keeping.",
            "Some **bold**, *italic*, and ***both*** words.",
            "<u>underlined</u> and ~~struck~~ text",
            "# A heading\n\nA paragraph.\n- First\n- Second\n\n1. One\n2. Two",
            "A [link](https://example.com) and `some code`.",
            "Emoji 👩🏽‍💻 and **中文** café",
            "A \\*literal\\* and \\[bracket\\].",
            "**Bold *italic* bold**",
            "**Bold <u>underlined</u> bold**",
            "[<u>underlined link</u>](https://example.com)",
            "\n\nTrailing blank lines\n\n"
        ]
        var failures = 0
        for sample in samples {
            let first = RichNoteCodec.decode(sample, dark: false)
            let encoded = RichNoteCodec.encode(first)
            let second = RichNoteCodec.decode(encoded, dark: false)
            if !first.isEqual(to: second) {
                print("FAIL round trip: \(sample) -> \(encoded)\n\(first)\n\(second)")
                failures += 1
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        let view = RichNoteTextView(frame: window.contentView!.bounds)
        view.isRichText = true
        view.allowsUndo = true
        window.contentView = view
        window.makeFirstResponder(view)
        view.textStorage?.setAttributedString(RichNoteCodec.decode("Selected words", dark: false))
        view.setSelectedRange(NSRange(location: 0, length: 8))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!
        assert(view.performKeyEquivalent(with: event))
        assert(RichNoteCodec.encode(view.textStorage!) == "**Selected** words")
        assert(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        assert(RichNoteCodec.encode(view.textStorage!) == "Selected words")
        view.textStorage?.setAttributedString(RichNoteCodec.decode("- First", dark: false))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertNewline(nil)
        assert(view.string == "• First\n• ")
        view.insertNewline(nil)
        assert(view.string == "• First\n")
        assert(RichNoteCodec.sourceOnlyReason("```swift\nlet x = 1\n```") != nil)
        assert(RichNoteCodec.sourceOnlyReason("| A | B |\n| --- | --- |\n| 1 | 2 |") != nil)
        print("Keyboard bold, undo, list continuation/exit, and source protection passed; \(samples.count - failures)/\(samples.count) round trips passed")
        if failures > 0 { exit(1) }
    }
}
