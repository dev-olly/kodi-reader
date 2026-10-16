import XCTest
@testable import EpubKit

final class NoteSketchTests: XCTestCase {
    private func annotation(sketches: [NoteSketch] = [], note: String? = nil) -> Annotation {
        Annotation(locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)), text: "Passage", note: note, sketches: sketches)
    }

    func testReferencesPreserveTitlesPositionsAndCode() {
        let first = NoteSketch(title: "Flow [A] \\ B"), second = NoteSketch(title: "Sketch 2")
        let text = "Emoji 👩🏽‍💻\n\n" + first.markdown + "\n\n```\n" + second.markdown + "\n```\n\n" + second.markdown
        let references = SketchReference.references(in: text)
        XCTAssertEqual(references.map(\.id), [first.id, second.id])
        XCTAssertEqual(references.map(\.title), [first.title, second.title])
        XCTAssertEqual((text as NSString).substring(with: references[0].range), first.markdown)
        let replaced = SketchReference.replacing(in: text) { $0.id == first.id ? "REMOVED" : second.markdown }
        XCTAssertTrue(replaced.contains("```\n" + second.markdown + "\n```"))
        XCTAssertFalse(replaced.contains(first.markdown))
        let cards = NoteMarkdown.previewBlocks(of: text).filter { if case .sketch = $0 { return true }; return false }
        XCTAssertEqual(cards, [.sketch(first.id, first.title), .sketch(second.id, second.title)])
    }

    func testCommandsRequireParagraphStartAndExcludeCode() {
        for command in ["/sketch", "/draw"] {
            let text = "Before 👋\n\n" + command
            XCTAssertEqual(SketchReference.commandRange(in: text, selection: NSRange(location: text.utf16.count, length: 0))?.length, command.utf16.count)
            for invalid in ["Prose " + command, "`" + command + "`", "```swift\n" + command, "~~~\n" + command, "    " + command] {
                XCTAssertNil(SketchReference.commandRange(in: invalid, selection: NSRange(location: invalid.utf16.count, length: 0)))
            }
        }
        let text = "```\ncode\n```\n/sketch"
        XCTAssertNotNil(SketchReference.commandRange(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
    }

    func testOldAnnotationsDecodeAndSketchMetadataRoundTrips() throws {
        let original = annotation()
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        object.removeValue(forKey: "sketches")
        XCTAssertTrue(try JSONDecoder().decode(Annotation.self, from: JSONSerialization.data(withJSONObject: object)).sketches.isEmpty)
        let sketch = NoteSketch(title: "Diagram")
        let note = annotation(sketches: [sketch], note: sketch.markdown)
        let decoded = try JSONDecoder().decode(Annotation.self, from: encoder.encode(note))
        XCTAssertEqual(decoded, note)
        XCTAssertTrue(decoded.hasDrawing)
    }

    func testSlashSuggestionsFilterAliasesAndExcludeCode() {
        for suffix in ["/", "/s", "/sk", "/sketch", "/d", "/draw"] {
            let note = "Before 👋\n\n" + suffix + "\n\nAfter"
            let caret = ("Before 👋\n\n" + suffix).utf16.count
            XCTAssertEqual(SketchReference.commandSuggestionRange(in: note, selection: NSRange(location: caret, length: 0)),
                           NSRange(location: caret - suffix.utf16.count, length: suffix.utf16.count))
        }
        for text in ["", "/unknown", "/sketches", "Text /sketch", "    /", "```\n/", "~~~\n/draw", "`/sketch`"] {
            XCTAssertNil(SketchReference.commandSuggestionRange(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
        }
        XCTAssertNil(SketchReference.commandSuggestionRange(in: "/sketch", selection: NSRange(location: 0, length: 7)))
    }

    func testIndependentScenesMigrationDeletionAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DrawingStore(rootDirectory: root)
        var old = annotation(note: "Existing text")
        old.hasDrawing = true
        try store.replaceScene(Data("legacy".utf8), bookID: "book", annotationID: old.id)
        let migrated = try store.migratingLegacyDrawing(old, bookID: "book")
        XCTAssertEqual(migrated.sketches.count, 1)
        XCTAssertEqual(try store.migratingLegacyDrawing(migrated, bookID: "book"), migrated)
        XCTAssertEqual(store.loadScene(bookID: "book", annotationID: old.id), Data("legacy".utf8))
        XCTAssertEqual(store.loadScene(bookID: "book", annotationID: old.id, sketchID: migrated.sketches[0].id), Data("legacy".utf8))
        let second = NoteSketch(title: "Sketch 2")
        var note = migrated
        note.sketches.append(second)
        note.note = (note.note ?? "") + "\n\n" + second.markdown
        try store.replaceSketch(scene: Data("second".utf8), preview: Data("preview".utf8), bookID: "book", annotationID: note.id, sketchID: second.id)
        let history = SketchUndoHistory()
        // One of two references disappearing must not delete its scene.
        let duplicate = (note.note ?? "") + "\n\n" + second.markdown
        var duplicated = note
        duplicated.note = duplicate
        let stillLinked = try history.reconciling(duplicated, note: note.note ?? "", drawings: store, bookID: "book")
        XCTAssertEqual(stillLinked.sketches.count, 2)
        let removedText = SketchReference.replacing(in: duplicate) { $0.id == second.id ? "" : NoteSketch(id: $0.id, title: $0.title).markdown }
        let removed = try history.reconciling(stillLinked, note: removedText, drawings: store, bookID: "book")
        try store.deleteSketch(bookID: "book", annotationID: note.id, sketchID: second.id)
        XCTAssertNil(store.loadScene(bookID: "book", annotationID: note.id, sketchID: second.id))
        XCTAssertEqual(store.loadScene(bookID: "book", annotationID: note.id, sketchID: migrated.sketches[0].id), Data("legacy".utf8))
        let undone = try history.reconciling(removed, note: duplicate, drawings: store, bookID: "book")
        XCTAssertEqual(Set(undone.sketches.map(\.id)), Set(note.sketches.map(\.id)))
        XCTAssertEqual(store.loadScene(bookID: "book", annotationID: note.id, sketchID: second.id), Data("second".utf8))
        XCTAssertEqual(store.loadPreview(bookID: "book", annotationID: note.id, sketchID: second.id), Data("preview".utf8))
        store.deleteScene(bookID: "book", annotationID: note.id)
        XCTAssertNil(store.loadScene(bookID: "book", annotationID: note.id, sketchID: second.id))
        XCTAssertNil(store.loadScene(bookID: "book", annotationID: note.id))
    }
}
