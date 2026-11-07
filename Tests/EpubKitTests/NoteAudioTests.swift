import XCTest
@testable import EpubKit

final class NoteAudioTests: XCTestCase {
    private func annotation(recordings: [NoteAudio] = [], note: String? = nil) -> Annotation {
        Annotation(locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)),
                   text: "Passage", note: note, audioRecordings: recordings)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testOldAnnotationsDecodeAndAudioMetadataRoundTrips() throws {
        let encoder = JSONEncoder()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(annotation())) as? [String: Any])
        old.removeValue(forKey: "audioRecordings")
        XCTAssertTrue(try JSONDecoder().decode(Annotation.self, from: JSONSerialization.data(withJSONObject: old)).audioRecordings.isEmpty)
        let recording = NoteAudio(title: "Thought on a passage", duration: 12.5, waveform: [0.1, 0.8, 0.2])
        var note = annotation(recordings: [recording], note: recording.markdown)
        note.color = .underline
        let decoded = try JSONDecoder().decode(Annotation.self, from: encoder.encode(note))
        XCTAssertEqual(decoded, note)
        XCTAssertTrue(decoded.hasContent)
        XCTAssertFalse(decoded.hasDrawing)
        XCTAssertEqual(decoded.visibleHighlightColor, .yellow)
    }

    func testSavedTranscriptIsOptionalAndRoundTripsWithSyncMetadata() throws {
        let original = NoteAudio(title: "Recorded thought", duration: 13.25,
            createdAt: Date(timeIntervalSince1970: 1_000), modifiedAt: Date(timeIntervalSince1970: 2_000), waveform: [0.2, 0.7])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "transcript")
        let decodedLegacy = try JSONDecoder().decode(NoteAudio.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decodedLegacy.transcript)
        XCTAssertEqual(decodedLegacy, original)

        var transcribed = original
        transcribed.transcript = "A thought <about> **this** passage.\nSecond line."
        let note = annotation(recordings: [transcribed], note: transcribed.markdown)
        let synced = SyncedAnnotation(annotation: note, drawing: nil)
        let restored = try JSONDecoder().decode(SyncedAnnotation.self, from: JSONEncoder().encode(synced))
        XCTAssertEqual(restored.annotation.audioRecordings, [transcribed])
        XCTAssertEqual(transcribed.id, original.id)
        XCTAssertEqual(transcribed.duration, original.duration)
        XCTAssertEqual(transcribed.createdAt, original.createdAt)
        XCTAssertEqual(transcribed.waveform, original.waveform)
        XCTAssertEqual(transcribed.markdown, original.markdown)
    }

    func testMixedReferencesPreserveEscapingOrderAndCode() {
        let first = NoteAudio(title: "Thought [A] \\ B", duration: 1)
        let second = NoteAudio(title: "Audio 2", duration: 2)
        let sketch = NoteSketch(title: "Diagram")
        let text = "Before 👩🏽‍💻\n\n" + first.markdown + "\n\n" + sketch.markdown
            + "\n\n```text\n" + second.markdown + "\n```\n\n" + second.markdown
            + "\n\n~~~\n" + first.markdown + "\n~~~"
        let references = AudioReference.references(in: text)
        XCTAssertEqual(references.map(\.id), [first.id, second.id])
        XCTAssertEqual(references.map(\.title), [first.title, second.title])
        XCTAssertEqual((text as NSString).substring(with: references[0].range), first.markdown)
        let blocks = NoteMarkdown.previewBlocks(of: text).filter {
            switch $0 { case .audio, .sketch: return true; default: return false }
        }
        XCTAssertEqual(blocks, [.audio(first.id, first.title), .sketch(sketch.id, sketch.title), .audio(second.id, second.title)])
        let replaced = AudioReference.replacing(in: text) { $0.id == second.id ? "removed" : first.markdown }
        XCTAssertTrue(replaced.contains("```text\n" + second.markdown + "\n```"))
        XCTAssertTrue(NoteMarkdown.plainPreview(of: first.markdown).contains(first.title))
        XCTAssertTrue(NoteMarkdown.unsupportedConstructs(in: first.markdown).isEmpty)
    }

    func testAudioCommandsExcludeProseCodeAndSelections() {
        for command in ["/", "/a", "/au", "/audio"] {
            let text = "Before 👋\n\n" + command + "\n\nAfter"
            let caret = ("Before 👋\n\n" + command).utf16.count
            XCTAssertEqual(AudioReference.commandSuggestionRange(in: text, selection: NSRange(location: caret, length: 0)),
                           NSRange(location: caret - command.utf16.count, length: command.utf16.count))
        }
        for text in ["", "/draw", "/audio-more", "Prose /audio", "    /audio", "```\n/audio", "~~~\n/audio", "`/audio`"] {
            XCTAssertNil(AudioReference.commandSuggestionRange(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
        }
        XCTAssertNil(AudioReference.commandRange(in: "/au", selection: NSRange(location: 3, length: 0)))
        XCTAssertNotNil(AudioReference.commandRange(in: "/audio", selection: NSRange(location: 6, length: 0)))
        XCTAssertNil(AudioReference.commandRange(in: "/audio", selection: NSRange(location: 0, length: 6)))
    }

    func testAtomicCopiesPreserveDraftAndExistingRecordingOnFailure() throws {
        let root = try temporaryDirectory()
        let store = AudioStore(rootDirectory: root)
        let annotationID = UUID(), audioID = UUID()
        let source = root.appendingPathComponent("draft.m4a")
        try Data("first audio".utf8).write(to: source)
        try store.saveRecording(from: source, bookID: "book / unsafe", annotationID: annotationID, audioID: audioID)
        let saved = store.recordingURL(bookID: "book / unsafe", annotationID: annotationID, audioID: audioID)
        XCTAssertTrue(saved.path.hasPrefix(store.recordingsDirectory.path + "/"))
        XCTAssertEqual(try Data(contentsOf: saved), Data("first audio".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertThrowsError(try store.saveRecording(from: root.appendingPathComponent("missing.m4a"), bookID: "book / unsafe", annotationID: annotationID, audioID: audioID))
        XCTAssertEqual(try Data(contentsOf: saved), Data("first audio".utf8))
        try Data().write(to: source)
        XCTAssertThrowsError(try store.saveRecording(from: source, bookID: "book / unsafe", annotationID: annotationID, audioID: audioID))
        XCTAssertEqual(try Data(contentsOf: saved), Data("first audio".utf8))
        try Data("replacement audio".utf8).write(to: source)
        try store.saveRecording(from: source, bookID: "book / unsafe", annotationID: annotationID, audioID: audioID)
        XCTAssertEqual(try Data(contentsOf: saved), Data("replacement audio".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement audio".utf8))
    }

    func testLastReferenceDeletionUndoRedoAndSessionCleanup() throws {
        let root = try temporaryDirectory()
        let store = AudioStore(rootDirectory: root)
        let recording = NoteAudio(title: "Audio 1", duration: 5)
        let source = root.appendingPathComponent("draft.m4a")
        try Data("recorded thoughts".utf8).write(to: source)
        let duplicate = recording.markdown + "\n\n" + recording.markdown
        let original = annotation(recordings: [recording], note: duplicate)
        try store.saveRecording(from: source, bookID: "book", annotationID: original.id, audioID: recording.id)
        let history = AudioUndoHistory()
        let once = try history.reconciling(original, note: recording.markdown, audio: store, bookID: "book")
        XCTAssertEqual(once.audioRecordings, [recording])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.recordingsDirectory.appendingPathComponent(".Undo").path))

        let removed = try history.reconciling(once, note: "Other prose", audio: store, bookID: "book")
        XCTAssertTrue(removed.audioRecordings.isEmpty)
        let live = store.recordingURL(bookID: "book", annotationID: original.id, audioID: recording.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "Reconciliation must not remove live files before the note checkpoint")
        try store.deleteRecording(bookID: "book", annotationID: original.id, audioID: recording.id)
        let restored = try history.reconciling(removed, note: duplicate, audio: store, bookID: "book")
        XCTAssertEqual(restored.audioRecordings, [recording])
        XCTAssertEqual(try Data(contentsOf: live), Data("recorded thoughts".utf8))
        let redone = try history.reconciling(restored, note: "Other prose", audio: store, bookID: "book")
        XCTAssertTrue(redone.audioRecordings.isEmpty)
        try store.deleteRecording(bookID: "book", annotationID: original.id, audioID: recording.id)
        history.discard()
        let undoDirectory = store.recordingsDirectory.appendingPathComponent(".Undo")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: undoDirectory.path)) ?? [], [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }

    func testBookRemovalCleansAudioSidecars() throws {
        let root = try temporaryDirectory()
        let library = LibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let recording = NoteAudio(title: "Audio", duration: 1)
        let note = annotation(recordings: [recording], note: recording.markdown)
        let source = root.appendingPathComponent("draft.m4a")
        try Data("audio".utf8).write(to: source)
        library.upsert(BookRecord(id: "book", title: "Book", author: "Author", annotations: [note]))
        try library.audioStore.saveRecording(from: source, bookID: "book", annotationID: note.id, audioID: recording.id)
        let url = library.audioStore.recordingURL(bookID: "book", annotationID: note.id, audioID: recording.id)
        library.remove(bookID: "book")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        library.flush()
    }

    func testPastedAudioCopiesAcrossNotesWithoutPublishingAndSurvivesSourceDeletion() throws {
        let root = try temporaryDirectory()
        let library = LibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let audio = NoteAudio(title: "Original thought", duration: 8, waveform: [0.2, 0.7], transcript: "Saved source transcript")
        let source = annotation(recordings: [audio], note: audio.markdown)
        let target = annotation(note: "Existing destination text")
        library.upsert(BookRecord(id: "book", title: "Book", author: "Author", annotations: [source, target]))
        let draft = root.appendingPathComponent("draft.m4a")
        try Data("independent recording".utf8).write(to: draft)
        try library.audioStore.saveRecording(from: draft, bookID: "book", annotationID: source.id, audioID: audio.id)
        let pasted = AudioReference.markdown(id: audio.id, title: "Pasted title [A]")
        let imported = try library.importReferencedAudio(in: target, note: pasted + "\n\n" + pasted, bookID: "book")
        XCTAssertEqual(imported.audioRecordings.count, 1)
        XCTAssertEqual(imported.audioRecordings[0].id, audio.id)
        XCTAssertEqual(imported.audioRecordings[0].title, "Pasted title [A]")
        XCTAssertEqual(imported.audioRecordings[0].waveform, audio.waveform)
        XCTAssertEqual(imported.audioRecordings[0].transcript, audio.transcript)
        XCTAssertEqual(imported.note, target.note, "Import prepares metadata; the caller publishes the new note text")
        XCTAssertEqual(library.record(for: "book")?.annotations.first(where: { $0.id == target.id }), target)
        library.audioStore.deleteRecordings(bookID: "book", annotationID: source.id)
        let destination = library.audioStore.recordingURL(bookID: "book", annotationID: target.id, audioID: audio.id)
        XCTAssertEqual(try Data(contentsOf: destination), Data("independent recording".utf8))

        // Re-pasting an already attached identity must not need its source again.
        let unchanged = try library.importReferencedAudio(in: imported, note: pasted + "\n\n" + pasted, bookID: "book")
        XCTAssertEqual(unchanged.audioRecordings, imported.audioRecordings)
        library.flush()
    }

    func testPastedAudioCopiesFromHiddenBookAndSurvivesSourceBookRemoval() throws {
        let root = try temporaryDirectory()
        let library = LibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let audio = NoteAudio(title: "Hidden book thought", duration: 2)
        let source = annotation(recordings: [audio], note: audio.markdown)
        let target = annotation()
        library.upsert(BookRecord(id: "hidden", title: "Source", author: "Author", annotations: [source]))
        library.hideFromRecents("hidden")
        library.upsert(BookRecord(id: "target", title: "Destination", author: "Author", annotations: [target]))
        let draft = root.appendingPathComponent("draft.m4a")
        try Data("cross book recording".utf8).write(to: draft)
        try library.audioStore.saveRecording(from: draft, bookID: "hidden", annotationID: source.id, audioID: audio.id)
        let imported = try library.importReferencedAudio(in: target, note: audio.markdown, bookID: "target")
        XCTAssertEqual(imported.audioRecordings, [audio])
        library.remove(bookID: "hidden")
        let destination = library.audioStore.recordingURL(bookID: "target", annotationID: target.id, audioID: audio.id)
        XCTAssertEqual(try Data(contentsOf: destination), Data("cross book recording".utf8))
        library.flush()
    }

    func testPastedKnownMissingAudioFailsBeforeAnyTargetCopiesAndKeepsAnnotations() throws {
        let root = try temporaryDirectory()
        let library = LibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let available = NoteAudio(title: "Downloaded recording", duration: 1)
        let missing = NoteAudio(title: "Pending download", duration: 3)
        let source = annotation(recordings: [available, missing], note: available.markdown + "\n\n" + missing.markdown)
        let target = annotation(note: "Existing target")
        library.upsert(BookRecord(id: "book", title: "Book", author: "Author", annotations: [source, target]))
        let draft = root.appendingPathComponent("draft.m4a")
        try Data("available audio".utf8).write(to: draft)
        try library.audioStore.saveRecording(from: draft, bookID: "book", annotationID: source.id, audioID: available.id)
        XCTAssertThrowsError(try library.importReferencedAudio(in: target, note: source.note!, bookID: "book")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Sync"))
            XCTAssertTrue(error.localizedDescription.contains(missing.title))
        }
        XCTAssertEqual(library.record(for: "book")?.annotations, [source, target])
        let targetURL = library.audioStore.recordingURL(bookID: "book", annotationID: target.id, audioID: available.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path), "Preflight all known donors before staging copies")
        let sourceURL = library.audioStore.recordingURL(bookID: "book", annotationID: source.id, audioID: available.id)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("available audio".utf8))
        library.flush()
    }

    func testUnresolvedPastedIdentityStaysAvailableForDiskUndoRestoration() throws {
        let root = try temporaryDirectory()
        let library = LibraryStore(fileURL: root.appendingPathComponent("library.json"))
        let target = annotation(note: "Before")
        library.upsert(BookRecord(id: "book", title: "Book", author: "Author", annotations: [target]))
        let unknown = NoteAudio(title: "Recording removed earlier", duration: 1)
        let imported = try library.importReferencedAudio(in: target, note: unknown.markdown, bookID: "book")
        XCTAssertEqual(imported, target)
        library.flush()
    }
}
