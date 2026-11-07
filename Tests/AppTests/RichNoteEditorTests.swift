import AppKit
import EpubKit
import SwiftUI

@main struct NoteEditorTests {
    @MainActor static func main() {
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
        assert(RichNoteCodec.sourceOnlyReason("A thought\n\n\n/audio") == nil, "Blank lines are not indented code")
        assert(RichNoteCodec.sourceOnlyReason("A thought\n\n  indented code") != nil)
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

        let recording = NoteAudio(title: "Thought [A] \\ B", duration: 32, waveform: [0.1, 0.8, 0.3])
        let mixedNote = "Before **bold** 👋\n\n" + firstSketch.markdown + "\n\n" + recording.markdown + "\n\nAfter *thoughts*"
        let mixedCards = RichNoteCodec.decode(mixedNote, dark: true)
        assert(RichNoteCodec.encode(mixedCards) == mixedNote)
        var audioRange: NSRange?
        mixedCards.enumerateAttribute(.attachment, in: NSRange(location: 0, length: mixedCards.length)) { value, range, _ in
            if let audio = value as? AudioTextAttachment {
                assert(audio.id == recording.id && audio.title == recording.title && !audio.isDraft)
                audioRange = range
            }
        }
        let recordingRange = audioRange!
        let audioMarkdownRange = RichNoteCodec.markdownRange(recordingRange, in: mixedCards)
        assert((mixedNote as NSString).substring(with: audioMarkdownRange) == recording.markdown)
        assert(RichNoteCodec.richRange(audioMarkdownRange, in: mixedCards) == recordingRange)
        view.textStorage?.setAttributedString(mixedCards)
        view.undoManager?.removeAllActions()
        view.insertText("", replacementRange: recordingRange)
        assert(AudioReference.references(in: RichNoteCodec.encode(view.textStorage!)).isEmpty)
        assert(SketchReference.references(in: RichNoteCodec.encode(view.textStorage!)).map(\.id) == [firstSketch.id])
        view.undoManager?.undo()
        assert(RichNoteCodec.encode(view.textStorage!) == mixedNote)
        view.undoManager?.redo()
        assert(AudioReference.references(in: RichNoteCodec.encode(view.textStorage!)).isEmpty)

        // The active draft is anchored by identity, not a stale source offset.
        let draftID = UUID()
        let draftMarker = AudioDraftReference.marker(draftID)
        let draftNote = "Before\n\n" + draftMarker + "\n\nAfter"
        let draftCards = RichNoteCodec.decode(draftNote, dark: true, audioDraftID: draftID)
        assert(RichNoteCodec.encode(draftCards) == draftNote)
        var draftAttachments = 0
        var liveDraft: AudioTextAttachment?
        draftCards.enumerateAttribute(.attachment, in: NSRange(location: 0, length: draftCards.length)) { value, _, _ in
            if let audio = value as? AudioTextAttachment {
                assert(audio.isDraft && audio.id == draftID)
                liveDraft = audio
                draftAttachments += 1
            }
        }
        assert(draftAttachments == 1)
        assert(liveDraft!.attachmentCell!.cellSize().height == 44, "The inline recorder retains its compact 44-point height")
        view.textStorage?.setAttributedString(draftCards)
        view.insertText(NSAttributedString(string: "An earlier thought 👋\n\n", attributes: RichNoteCodec.attributes(dark: true)),
                        replacementRange: NSRange(location: 0, length: 0))
        let editedDraft = RichNoteCodec.encode(view.textStorage!)
        assert(editedDraft.contains("An earlier thought 👋") && editedDraft.contains(draftMarker))
        let finished = NSMutableString(string: editedDraft)
        let movedMarker = finished.range(of: draftMarker)
        assert(movedMarker.location > (draftNote as NSString).range(of: draftMarker).location)
        finished.replaceCharacters(in: movedMarker, with: recording.markdown)
        assert(RichNoteCodec.encode(RichNoteCodec.decode(finished as String, dark: true)) == finished as String)
        assert(!AudioDraftReference.removing(draftID, from: editedDraft).contains(draftMarker))

        // Finishing a take replaces its draft projection through NSTextView's
        // native undo path. Undo must not resurrect an active recorder marker.
        view.undoManager?.removeAllActions()
        view.breakUndoCoalescing()
        liveDraft!.retireDraft()
        let completedNote = finished as String
        view.insertText(RichNoteCodec.decode(completedNote, dark: true),
                        replacementRange: NSRange(location: 0, length: view.string.utf16.count))
        assert(RichNoteCodec.encode(view.textStorage!) == completedNote)
        assert(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        let undoneTake = RichNoteCodec.encode(view.textStorage!)
        assert(!undoneTake.contains("kodi-audio-draft:"))
        assert(AudioReference.references(in: undoneTake).isEmpty)
        assert(undoneTake.contains("An earlier thought 👋") && undoneTake.contains("Before") && undoneTake.contains("After"))
        view.resizeSketchCards()
        assert(view.subviews.compactMap { $0 as? NSHostingView<AnyView> }.isEmpty,
               "Undo after finish must not restore a live recorder overlay")
        view.undoManager?.redo()
        let redoneTake = RichNoteCodec.encode(view.textStorage!)
        assert(!redoneTake.contains("kodi-audio-draft:"))
        assert(redoneTake == completedNote)
        assert(AudioReference.references(in: redoneTake).map(\.id) == [recording.id])

        var completedAudioRange: NSRange?
        view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
            if let audio = value as? AudioTextAttachment, audio.id == recording.id { completedAudioRange = range }
        }
        view.undoManager?.removeAllActions()
        view.breakUndoCoalescing()
        view.insertText("", replacementRange: completedAudioRange!)
        assert(AudioReference.references(in: RichNoteCodec.encode(view.textStorage!)).isEmpty)
        view.undoManager?.undo()
        assert(AudioReference.references(in: RichNoteCodec.encode(view.textStorage!)).map(\.id) == [recording.id])
        assert(!RichNoteCodec.encode(view.textStorage!).contains("kodi-audio-draft:"))
        view.undoManager?.redo()
        assert(AudioReference.references(in: RichNoteCodec.encode(view.textStorage!)).isEmpty)
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

        let enter = keyEvent(window: window, keyCode: 36, characters: "\r")
        let escape = keyEvent(window: window, keyCode: 53, characters: "\u{1b}")
        let down = keyEvent(window: window, keyCode: 125, characters: "\u{F701}")
        let up = keyEvent(window: window, keyCode: 126, characters: "\u{F700}")
        for editor in [view as SketchCommandTextView, sourceView] {
            if let rich = editor as? RichNoteTextView {
                rich.textStorage?.setAttributedString(NSAttributedString(string: "", attributes: RichNoteCodec.attributes(dark: false)))
                rich.typingAttributes = RichNoteCodec.attributes(dark: false)
            }
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            var createdAudio: NSRange?
            var createdSketch: NSRange?
            editor.onCreateAudio = { createdAudio = $0 }
            editor.onCreateSketch = { createdSketch = $0 }

            editor.string = "Before\n\n/audio"
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.commandChanged()
            assert(editor.isCommandSuggestionVisible)
            assert(editor.performKeyEquivalent(with: enter))
            assert(createdAudio == NSRange(location: 8, length: 6) && createdSketch == nil)
            assert(editor.string == "Before\n\n/audio", "Enter must route to recording without adding a newline")

            for selectAudio in [false, true] {
                // Move through a normal paragraph to clear a dismissed command.
                editor.string = "Paragraph"
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                editor.commandChanged()
                editor.string = "/"
                editor.setSelectedRange(NSRange(location: 1, length: 0))
                createdAudio = nil; createdSketch = nil
                editor.commandChanged()
                assert(editor.isCommandSuggestionVisible)
                if selectAudio { assert(editor.performKeyEquivalent(with: down)) }
                assert(editor.performKeyEquivalent(with: enter))
                if selectAudio {
                    assert(createdAudio == NSRange(location: 0, length: 1) && createdSketch == nil)
                } else {
                    assert(createdSketch == NSRange(location: 0, length: 1) && createdAudio == nil)
                }
            }

            // Up/Down wraps through the two slash actions without moving text.
            editor.string = "Paragraph"; editor.setSelectedRange(NSRange(location: 9, length: 0)); editor.commandChanged()
            editor.string = "/"; editor.setSelectedRange(NSRange(location: 1, length: 0)); editor.commandChanged()
            createdAudio = nil; createdSketch = nil
            assert(editor.performKeyEquivalent(with: up))
            assert(editor.performKeyEquivalent(with: enter))
            assert(createdAudio == NSRange(location: 0, length: 1) && createdSketch == nil)

            editor.string = "/audio"
            editor.setSelectedRange(NSRange(location: 6, length: 0))
            editor.commandChanged()
            createdAudio = nil
            editor.keyDown(with: escape)
            assert(!editor.isCommandSuggestionVisible)
            assert(!editor.performKeyEquivalent(with: enter))
            assert(createdAudio == nil)
            editor.suppressPastedCommand()
            editor.commandChanged()
            assert(!editor.isCommandSuggestionVisible)
            assert(!editor.handleSketchCommand(#selector(NSResponder.insertNewline(_:))))

            for code in ["```\n/audio", "~~~\n/audio"] {
                editor.string = code
                editor.setSelectedRange(NSRange(location: code.utf16.count, length: 0))
                editor.commandChanged()
                assert(editor.commandCandidate() == nil)
                assert(!editor.isCommandSuggestionVisible)
            }
        }
        view.textStorage?.setAttributedString(RichNoteCodec.decode("`/audio`", dark: true))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        assert(view.commandCandidate() == nil)

        // Native audio attachments host interactive views at sidebar width.
        var permissionRequests = 0
        let controller = AudioNoteController(permission: { permissionRequests += 1; return false })
        let audioFixture = FileManager.default.temporaryDirectory.appendingPathComponent("kodi-editor-" + UUID().uuidString + ".m4a")
        try! Data("unused playback fixture".utf8).write(to: audioFixture)
        defer { try? FileManager.default.removeItem(at: audioFixture) }
        view.audioContext = AudioNoteEditorContext(controller: controller,
            recordings: [recording.id: recording], fileURL: { _ in audioFixture },
            onRename: { _ in }, onExport: { _ in }, onDelete: { _ in },
            draftID: nil, draftError: nil, onFinishDraft: {}, onDiscardDraft: {})
        window.contentView = view
        view.textStorage?.setAttributedString(RichNoteCodec.decode(recording.markdown, dark: true))
        view.setFrameSize(NSSize(width: 300, height: 640))
        view.resizeSketchCards()
        view.layoutSubtreeIfNeeded()
        let players = view.subviews.compactMap { $0 as? NSHostingView<AnyView> }
        assert(players.count == 1)
        let player = players[0]
        assert(player.frame.width > 0 && player.frame.maxX <= view.bounds.maxX)
        assert(player.frame.height == AudioNoteCardLayout.baseHeight)
        player.layoutSubtreeIfNeeded()
        let playerPoint = NSPoint(x: player.frame.minX + 22, y: player.frame.midY)
        let hit = view.hitTest(view.convert(playerPoint, to: view.superview))
        assert(hit === player || hit?.isDescendant(of: player) == true,
               "Audio playback controls must receive pointer events rather than the underlying text attachment")
        assert(player.accessibilityRole() == .group)
        let audioAttachment = view.textStorage!.attribute(.attachment, at: 0, effectiveRange: nil) as! AudioTextAttachment
        let liveAudioCell = audioAttachment.attachmentCell as! AudioAttachmentCell
        assert(liveAudioCell.hasLiveOverlay && !attachmentPaintsPixels(liveAudioCell),
               "A live audio card must not repaint its fallback underneath the hosted controls")
        assert(attachmentPaintsPixels(AudioAttachmentCell(title: recording.title)),
               "An audio attachment without an editor context still needs a readable fallback")

        settleLayout(player)
        let seekSlider = nativeDescendants(player).compactMap { $0 as? NSSlider }.first!
        assert(window.makeFirstResponder(seekSlider) && window.firstResponder === seekSlider,
               "The saved card exposes a real keyboard-focusable seek control")
        settleLayout(player)
        let stableFrame = player.frame
        let stablePixels = renderedPixels(player)
        var frameChanges = 0
        player.postsFrameChangedNotifications = true
        let frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
            object: player, queue: nil) { _ in frameChanges += 1 }
        for _ in 0..<12 {
            view.refreshAudioOverlays(updateContent: true)
            view.resizeSketchCards()
            view.layoutSubtreeIfNeeded()
        }
        settleLayout(player)
        NotificationCenter.default.removeObserver(frameObserver)
        assert(view.subviews.compactMap { $0 as? NSHostingView<AnyView> }.first === player,
               "Unchanged text-layout refreshes retain the same audio hosting view")
        assert(player.frame == stableFrame && frameChanges == 0,
               "Unchanged audio cards must not churn native frame notifications")
        assert(nativeDescendants(player).contains { $0 === seekSlider } && window.firstResponder === seekSlider,
               "Repeated note refreshes preserve the focused seek control")
        assert(renderedPixels(player) == stablePixels, "An idle saved card renders the same pixels after repeated refreshes")

        // Stable idle views must still reflect real metadata, download, and
        // appearance changes without replacing their native container.
        window.makeFirstResponder(view)
        settleLayout(player)
        let originalPixels = renderedPixels(player)
        var changedRecording = recording
        changedRecording.duration = 81
        changedRecording.createdAt = Date(timeIntervalSince1970: 1_600_000_000)
        changedRecording.waveform = [0.9, 0.05, 0.95, 0.1]
        view.audioContext!.recordings[recording.id] = changedRecording
        view.refreshAudioOverlays(updateContent: true)
        settleLayout(player)
        assert(renderedPixels(player) != originalPixels, "Changed duration, date, and waveform update the visible saved card")
        assert(player.frame == stableFrame && view.subviews.contains { $0 === player })

        view.audioContext!.fileURL = { _ in nil }
        view.refreshAudioOverlays(updateContent: true)
        settleLayout(player)
        assert(nativeDescendants(player).compactMap { $0 as? NSSlider }.first?.isEnabled == false,
               "A pending recording download disables its seek control")
        view.audioContext!.fileURL = { _ in audioFixture }
        view.refreshAudioOverlays(updateContent: true)
        settleLayout(player)
        assert(nativeDescendants(player).compactMap { $0 as? NSSlider }.first?.isEnabled == true,
               "Finishing a download enables playback controls in the existing host")

        view.dark = true
        view.refreshAudioOverlays(updateContent: true)
        settleLayout(player)
        assert(player.appearance?.name == .darkAqua)
        let darkPixels = renderedPixels(player)
        view.dark = false
        view.refreshAudioOverlays(updateContent: true)
        settleLayout(player)
        assert(player.appearance?.name == .aqua && renderedPixels(player) != darkPixels,
               "Appearance changes refresh both the native host and audio card colors")

        view.audioContext!.expandedTranscripts.insert(recording.id)
        view.resizeSketchCards()
        assert(player.frame.height == AudioNoteCardLayout.baseHeight, "An empty transcript reserves no expanded space")
        changedRecording.transcript = "A saved thought about this book.\nA second line remains readable."
        view.audioContext!.recordings[recording.id] = changedRecording
        view.resizeSketchCards()
        settleLayout(player)
        assert(player.frame.height == AudioNoteCardLayout.baseHeight + AudioNoteCardLayout.transcriptExtraHeight,
               "Saving an expanded transcript grows the attachment and its live card together")
        assert(liveAudioCell.cellSize().height == player.frame.height)
        assert(view.subviews.compactMap { $0 as? NSHostingView<AnyView> }.first === player)
        view.audioContext!.transcriptionErrors[recording.id] = "Try this saved recording again."
        view.resizeSketchCards()
        settleLayout(player)
        assert(player.frame.height == AudioNoteCardLayout.baseHeight + AudioNoteCardLayout.transcriptExtraHeight + AudioNoteCardLayout.statusExtraHeight,
               "Transcription status gets its own reserved row")
        view.audioContext!.expandedTranscripts.remove(recording.id)
        view.audioContext!.transcriptionErrors = [:]
        view.resizeSketchCards()
        settleLayout(player)
        assert(player.frame.height == AudioNoteCardLayout.baseHeight && liveAudioCell.cellSize().height == player.frame.height,
               "Collapsing the transcript restores the saved card's base height")
        assert(permissionRequests == 0, "Rendering and inspecting audio controls must never request microphone access")
        view.audioContext = nil
        view.resizeSketchCards()
        assert(view.subviews.compactMap { $0 as? NSHostingView<AnyView> }.isEmpty)
        assert(!liveAudioCell.hasLiveOverlay && attachmentPaintsPixels(liveAudioCell),
               "Removing the editor context restores audio fallback rendering")

        // Cut can remove the source's last live file before a different note
        // receives Paste. Clipboard retention must own an independent file.
        let clipboardRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kodi-editor-clipboard-" + UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: clipboardRoot, withIntermediateDirectories: true)
        defer {
            AudioNoteClipboard.clear()
            try? FileManager.default.removeItem(at: clipboardRoot)
        }
        let clipboardSource = clipboardRoot.appendingPathComponent("source.m4a")
        let clipboardBytes = Data("thought retained across Cut and source-note closure".utf8)
        try! clipboardBytes.write(to: clipboardSource)
        let copiedAudio = NoteAudio(title: "Original clipboard thought", duration: 14.5, waveform: [0.1, 0.8, 0.4])
        let clipboardContext = AudioNoteEditorContext(controller: controller,
            recordings: [copiedAudio.id: copiedAudio], fileURL: { $0 == copiedAudio.id ? clipboardSource : nil },
            onRename: { _ in }, onExport: { _ in }, onDelete: { _ in },
            draftID: nil, draftError: nil, onFinishDraft: {}, onDiscardDraft: {})
        let pastedTitle = "Pasted [thought]"
        let copiedLink = AudioReference.markdown(id: copiedAudio.id, title: pastedTitle)
        let copiedMarkdown = copiedLink + "\n\n" + copiedLink
        AudioNoteClipboard.retain(copiedMarkdown, context: clipboardContext)
        try! FileManager.default.removeItem(at: clipboardSource)
        let clipboardTarget = Annotation(locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)),
                                         text: "Destination passage", note: "Existing destination text")
        let clipboardStore = AudioStore(rootDirectory: clipboardRoot.appendingPathComponent("destination", isDirectory: true))
        let pasted = try! AudioNoteClipboard.importing(into: clipboardTarget, note: copiedMarkdown,
                                                      audio: clipboardStore, bookID: "destination-book")
        var expectedAudio = copiedAudio
        expectedAudio.title = pastedTitle
        assert(pasted.audioRecordings == [expectedAudio], "Duplicate copied references must share one metadata record with the pasted title")
        assert(pasted.note == clipboardTarget.note, "Clipboard import does not publish the surrounding note text")
        let pastedFile = clipboardStore.recordingURL(bookID: "destination-book", annotationID: clipboardTarget.id, audioID: copiedAudio.id)
        assert(try! Data(contentsOf: pastedFile) == clipboardBytes)
        let pastedAgain = try! AudioNoteClipboard.importing(into: pasted, note: copiedMarkdown,
                                                           audio: clipboardStore, bookID: "destination-book")
        assert(pastedAgain.audioRecordings == [expectedAudio])
        AudioNoteClipboard.clear()
        assert(try! Data(contentsOf: pastedFile) == clipboardBytes,
               "Releasing clipboard retention must not remove a pasted recording's live file")
        let afterClipboardClear = try! AudioNoteClipboard.importing(into: clipboardTarget, note: copiedMarkdown,
                                                                   audio: clipboardStore, bookID: "another-book")
        assert(afterClipboardClear.audioRecordings.isEmpty)
        assert(permissionRequests == 0)

        // Reminder rows keep their identity across codecs, source/rich selection,
        // and native Undo. The canonical task survives removing a note reference.
        let reminder = ResearchReminder(title: "Research sharding 👋", source: .note,
            locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)))
        let reminderLink = ReminderReference.markdown(id: reminder.id, title: reminder.title)
        let reminderMarkdown = "Before **bold** 👋\n\n" + reminderLink + "\n\nAfter"
        let reminderDecoded = RichNoteCodec.decode(reminderMarkdown, dark: false)
        assert(RichNoteCodec.encode(reminderDecoded) == reminderMarkdown)
        assert(RichNoteCodec.sourceOnlyReason(reminderMarkdown) == nil)
        var reminderRange: NSRange?
        reminderDecoded.enumerateAttribute(.attachment, in: NSRange(location: 0, length: reminderDecoded.length)) { value, range, _ in
            if let attachment = value as? ReminderTextAttachment, attachment.id == reminder.id { reminderRange = range }
        }
        let reminderSelection = reminderRange!
        let reminderMarkdownRange = RichNoteCodec.markdownRange(reminderSelection, in: reminderDecoded)
        assert((reminderMarkdown as NSString).substring(with: reminderMarkdownRange) == reminderLink)
        view.textStorage?.setAttributedString(reminderDecoded)
        view.undoManager?.removeAllActions()
        view.setSelectedRange(reminderSelection)
        view.insertText("", replacementRange: reminderSelection)
        assert(ReminderReference.references(in: RichNoteCodec.encode(view.textStorage!)).isEmpty)
        view.undoManager?.undo()
        assert(RichNoteCodec.encode(view.textStorage!) == reminderMarkdown)

        for editor in [view as SketchCommandTextView, sourceView] {
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            var createdReminder: NSRange?
            editor.onCreateReminder = { createdReminder = $0 }
            for command in ["/remind", "/task", "/remind Research sharding 👋", "/task Read more"] {
                editor.string = "Normal"; editor.setSelectedRange(NSRange(location: 6, length: 0)); editor.commandChanged()
                editor.string = "Before 👋\n\n" + command
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                createdReminder = nil
                editor.commandChanged()
                assert(editor.isCommandSuggestionVisible)
                assert(editor.performKeyEquivalent(with: enter))
                let expected = NSRange(location: "Before 👋\n\n".utf16.count, length: command.utf16.count)
                assert(createdReminder == expected)
                assert(editor.string.hasSuffix(command), "The caller replaces the command only after durable save")
                editor.keyDown(with: escape)
                createdReminder = nil
                assert(!editor.performKeyEquivalent(with: enter))
                assert(createdReminder == nil)
            }
            editor.string = "Normal"; editor.setSelectedRange(NSRange(location: 6, length: 0)); editor.commandChanged()
            editor.string = "/"; editor.setSelectedRange(NSRange(location: 1, length: 0)); editor.commandChanged()
            assert(editor.performKeyEquivalent(with: down))
            assert(editor.performKeyEquivalent(with: down))
            createdReminder = nil
            assert(editor.performKeyEquivalent(with: enter))
            assert(createdReminder == NSRange(location: 0, length: 1))
            editor.onCreateReminder = nil
        }
        view.textStorage?.setAttributedString(RichNoteCodec.decode("`/remind`", dark: false))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        assert(view.commandCandidate() == nil)

        window.contentView = view
        view.textStorage?.setAttributedString(RichNoteCodec.decode(reminderLink, dark: false))
        var canonical = reminder
        var reminderToggles = 0, reminderEdits = 0
        view.reminderContext = ReminderNoteEditorContext(reminder: { _ in canonical },
            onToggle: { _ in reminderToggles += 1; canonical.completedAt = canonical.isCompleted ? nil : Date() },
            onEdit: { _ in reminderEdits += 1 })
        view.setFrameSize(NSSize(width: 300, height: 640))
        view.resizeSketchCards()
        let reminderHosts = view.subviews.compactMap { $0 as? NSHostingView<ReminderInlineRow> }
        assert(reminderHosts.count == 1 && reminderHosts[0].frame.width > 0)
        assert(reminderHosts[0].frame.maxX <= view.bounds.maxX)
        view.layoutSubtreeIfNeeded()
        let reminderCell = view.textStorage!.attribute(.attachment, at: 0, effectiveRange: nil) as! ReminderTextAttachment
        let liveReminderCell = reminderCell.attachmentCell as! ReminderAttachmentCell
        assert(liveReminderCell.hasLiveOverlay && !attachmentPaintsPixels(liveReminderCell),
               "A live row must not paint a duplicate fallback title underneath its translucent background")
        let standaloneReminderCell = ReminderAttachmentCell(title: reminder.title)
        assert(attachmentPaintsPixels(standaloneReminderCell), "Standalone attachment rendering keeps readable fallback text")
        assert(view.accessibilityChildren()?.compactMap { $0 as? ReminderAccessibilityAction }.count == 2)
        let reminderAX = accessibilityNodes(view)
        let completeButton = reminderAX.first { $0.accessibilityRole() == .checkBox && $0.accessibilityLabel()?.hasPrefix("Complete reminder:") == true }
        let editButton = reminderAX.first { $0.accessibilityRole() == .button && $0.accessibilityLabel()?.hasPrefix("Edit reminder:") == true }
        assert(completeButton != nil && editButton != nil, "Hosted reminder actions must be discoverable through the text editor's accessibility children")
        assert(completeButton!.accessibilityFrame().width == 28 && completeButton!.accessibilityFrame().height == 36)
        assert(completeButton!.accessibilityPerformPress())
        assert(editButton!.accessibilityPerformPress())
        assert(reminderToggles == 1 && canonical.isCompleted && reminderEdits == 1)
        let reminderPoint = NSPoint(x: reminderHosts[0].frame.minX + 26, y: reminderHosts[0].frame.midY)
        let reminderHit = view.hitTest(view.convert(reminderPoint, to: view.superview))
        assert(reminderHit === reminderHosts[0] || reminderHit?.isDescendant(of: reminderHosts[0]) == true)
        canonical.title = "Canonical updated title"; canonical.completedAt = Date()
        view.resizeSketchCards()
        assert(reminderHosts[0].rootView.title == canonical.title && reminderHosts[0].rootView.isCompleted)
        view.reminderContext = nil
        view.resizeSketchCards()
        assert(!liveReminderCell.hasLiveOverlay && attachmentPaintsPixels(liveReminderCell), "Removing live context restores fallback rendering")
        assert(view.subviews.compactMap { $0 as? NSHostingView<ReminderInlineRow> }.isEmpty)
        view.textStorage?.setAttributedString(RichNoteCodec.decode("Unlinked", dark: false))
        view.resizeSketchCards()
        assert(view.subviews.compactMap { $0 as? NSHostingView<ReminderInlineRow> }.isEmpty)
        assert(canonical.id == reminder.id, "Unlinking a note reference leaves canonical reminder storage alone")
        print("Reminder aliases, command tails, shared slash selection, rich/source mapping, native Undo, canonical refresh, and 300pt rows passed")

        print("Rich and Source slash suggestions, native Return routing, prefix activation, Escape, paste suppression, and normal Enter passed")
        print("Multiple sketch cards, identity/formatting round trips, selection mapping, delete undo/redo, both slash commands, and Escape passed")
        print("Mixed audio/sketch round trips, finished-take and deletion Undo/Redo, retired drafts, retained Cut/Paste files, /audio routing, slash selection, and 300pt interactive players passed")
        print("Audio fallback suppression, stable host/focus/frame/pixels, metadata/download/appearance refresh, and transcript/status attachment heights passed")
        print("Keyboard bold, undo, list continuation/exit, and source protection passed; \(samples.count - failures)/\(samples.count) round trips passed")
        if failures > 0 { exit(1) }
    }

    @MainActor private static func accessibilityNodes(_ element: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 12, let node = element as? NSAccessibilityProtocol else { return [] }
        return [node] + (node.accessibilityChildren() ?? []).flatMap { accessibilityNodes($0, depth: depth + 1) }
    }

    @MainActor private static func attachmentPaintsPixels(_ cell: NSTextAttachmentCell) -> Bool {
        let size = cell.cellSize()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(ceil(size.width))), pixelsHigh: max(1, Int(ceil(size.height))),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let count = bitmap.bytesPerRow * bitmap.pixelsHigh
        for offset in 0..<count { bitmap.bitmapData![offset] = 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        cell.draw(withFrame: NSRect(origin: .zero, size: size), in: nil)
        NSGraphicsContext.restoreGraphicsState()
        return UnsafeBufferPointer(start: bitmap.bitmapData!, count: count).contains { $0 != 0 }
    }

    @MainActor private static func nativeDescendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + nativeDescendants($0) }
    }

    @MainActor private static func settleLayout(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    @MainActor private static func renderedPixels(_ view: NSView) -> Data {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        let count = bitmap.bytesPerRow * bitmap.pixelsHigh
        for offset in 0..<count { bitmap.bitmapData![offset] = 0 }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return Data(bytes: bitmap.bitmapData!, count: count)
    }

    @MainActor private static func keyEvent(window: NSWindow, keyCode: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }
}
