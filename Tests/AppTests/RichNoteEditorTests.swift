import AppKit
import EpubKit
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
        let firstSketch = NoteSketch(title: "Flow [A]"), secondSketch = NoteSketch(title: "Sketch 2")
        let sketchNote = "Before **bold** 👋\n\n" + firstSketch.markdown + "\n\nBetween\n\n" + secondSketch.markdown + "\n\nAfter"
        let cards = RichNoteCodec.decode(sketchNote, dark: false)
        assert(RichNoteCodec.encode(cards) == sketchNote)
        var ids: [UUID] = []
        cards.enumerateAttribute(.attachment, in: NSRange(location: 0, length: cards.length)) { value, _, _ in
            if let sketch = value as? SketchTextAttachment { ids.append(sketch.id) }
        }
        assert(ids == [firstSketch.id, secondSketch.id])
        assert(RichNoteCodec.sourceOnlyReason(sketchNote) == nil)
        let cardRange = (cards.string as NSString).range(of: "\u{FFFC}")
        let markdownRange = RichNoteCodec.markdownRange(cardRange, in: cards)
        assert((sketchNote as NSString).substring(with: markdownRange) == firstSketch.markdown)
        assert(RichNoteCodec.richRange(markdownRange, in: cards) == cardRange)
        view.textStorage?.setAttributedString(cards)
        view.undoManager?.removeAllActions()
        view.insertText("", replacementRange: cardRange)
        assert(SketchReference.references(in: RichNoteCodec.encode(view.textStorage!)).map(\.id) == [secondSketch.id])
        view.undoManager?.undo()
        assert(RichNoteCodec.encode(view.textStorage!) == sketchNote)
        view.undoManager?.redo()
        assert(SketchReference.references(in: RichNoteCodec.encode(view.textStorage!)).map(\.id) == [secondSketch.id])
        for command in ["/sketch", "/draw"] {
            view.textStorage?.setAttributedString(RichNoteCodec.decode("Before\n\n" + command, dark: false))
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            var created: NSRange?
            view.onCreateSketch = { created = $0 }
            view.insertNewline(nil)
            assert(created?.length == command.utf16.count)
            assert(view.string.hasSuffix(command), "Command should not insert a newline")
            created = nil
            assert(view.handleSketchCommand(#selector(NSResponder.cancelOperation(_:))))
            assert(!view.handleSketchCommand(#selector(NSResponder.insertNewline(_:))))
            assert(created == nil)
        }
        // Exercise actual key routing, rather than only insertNewline selectors.
        let sourceView = NoteTextView(frame: view.bounds)
        sourceView.isRichText = false
        for editor in [view as SketchCommandTextView, sourceView] {
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            for command in ["/sketch", "/draw", "/"] {
                editor.string = "Before\n\n"
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                editor.insertText(command, replacementRange: editor.selectedRange())
                var created: NSRange?
                editor.onCreateSketch = { created = $0 }
                editor.commandChanged()
                assert(editor.isCommandSuggestionVisible)
                let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                assert(editor.performKeyEquivalent(with: enter))
                assert(created == NSRange(location: 8, length: command.utf16.count))
                assert(!editor.isCommandSuggestionVisible)
                created = nil
                editor.keyDown(with: enter)
                assert(created != nil)
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                editor.commandChanged()
                editor.keyDown(with: escape)
                assert(!editor.isCommandSuggestionVisible)
                created = nil
                assert(!editor.performKeyEquivalent(with: enter))
                assert(created == nil)
                editor.string = ""
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                editor.commandChanged()
            }
            editor.string = "/sketch"
            editor.setSelectedRange(NSRange(location: 7, length: 0))
            editor.suppressPastedCommand()
            editor.commandChanged()
            assert(!editor.isCommandSuggestionVisible)
            assert(!editor.handleSketchCommand(#selector(NSResponder.insertNewline(_:))))
            editor.string = "Normal paragraph"
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertNewline(nil)
            assert(editor.string == "Normal paragraph\n")
        }
        view.textStorage?.setAttributedString(RichNoteCodec.decode("`/sketch`", dark: false))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        assert(view.commandCandidate() == nil)
        print("Rich and Source slash suggestions, native Return routing, prefix activation, Escape, paste suppression, and normal Enter passed")
        print("Multiple sketch cards, identity/formatting round trips, selection mapping, delete undo/redo, both slash commands, and Escape passed")
        print("Keyboard bold, undo, list continuation/exit, and source protection passed; \(samples.count - failures)/\(samples.count) round trips passed")
        if failures > 0 { exit(1) }
    }
}
