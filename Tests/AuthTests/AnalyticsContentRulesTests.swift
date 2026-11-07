import EpubKit
import Foundation
import XCTest

final class AnalyticsContentRulesTests: XCTestCase {
    func testMediaReferencesAreNotTextNotes() {
        let sketch = SketchReference.markdown(id: UUID(), title: "Sketch 1")
        let audio = AudioReference.markdown(id: UUID(), title: "Audio note 1")
        XCTAssertTrue(AnalyticsContentRules.textNote(" \n\(sketch)\n\n\(audio)\n").isEmpty)
        XCTAssertEqual(AnalyticsContentRules.textNote("My idea\n\n\(sketch)\n"), "My idea")
        XCTAssertEqual(AnalyticsContentRules.textNote("My idea\n\n\(audio)\n"), "My idea")
        XCTAssertNotEqual(AnalyticsContentRules.textNote("My idea"), AnalyticsContentRules.textNote(""), "Deleting an existing note's text is still a meaningful edit")
    }

    func testCodeContainingAReferenceRemainsText() {
        let sketch = SketchReference.markdown(id: UUID(), title: "Example")
        XCTAssertFalse(AnalyticsContentRules.textNote("```md\n\(sketch)\n```").isEmpty)
    }

    func testReturningToAnEmptiedItemCountsAnEditRatherThanAnotherCreation() {
        var tracker = AnalyticsEditTracker()
        let created = tracker.begin(kind: .note, itemKey: "local-note", isNew: true, content: .epub, now: 0)
        XCTAssertEqual(tracker.didPersist(created, meaningful: true)?.name, .noteCreated)
        tracker.end(created)
        let resumed = tracker.begin(kind: .note, itemKey: "local-note", isNew: true, content: .epub, now: 2)
        XCTAssertEqual(tracker.didPersist(resumed, meaningful: true)?.name, .noteEditSession)
        XCTAssertNil(tracker.didPersist(resumed, meaningful: true))
    }

    func testCanvasViewAndAutosaveMetadataDoNotCountAsDrawingEdits() throws {
        let before = try scene(elements: [["id": "shape", "x": 1, "y": 2, "version": 1, "versionNonce": 5, "updated": 10]], state: ["zoom": 1])
        let after = try scene(elements: [["id": "shape", "x": 1, "y": 2, "version": 2, "versionNonce": 6, "updated": 20]], state: ["zoom": 3, "scrollX": 200])
        XCTAssertEqual(AnalyticsContentRules.drawingSignature(before), AnalyticsContentRules.drawingSignature(after))
        let moved = try scene(elements: [["id": "shape", "x": 3, "y": 2]], state: [:])
        XCTAssertNotEqual(AnalyticsContentRules.drawingSignature(before), AnalyticsContentRules.drawingSignature(moved))
    }

    func testDeletingContentAndChangingReferencedImagesAreMeaningful() throws {
        let before = try scene(elements: [["id": "shape", "x": 1]], state: [:])
        let removed = try scene(elements: [["id": "shape", "x": 1, "isDeleted": true]], state: [:])
        let empty = try scene(elements: [], state: [:])
        XCTAssertNotEqual(AnalyticsContentRules.drawingSignature(before), AnalyticsContentRules.drawingSignature(removed))
        XCTAssertEqual(AnalyticsContentRules.drawingSignature(removed), AnalyticsContentRules.drawingSignature(empty))
        func imageScene(_ image: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["elements": [["id": "image", "fileId": "local-image"]], "files": ["local-image": ["mimeType": "image/png", "dataURL": image]]])
        }
        XCTAssertNotEqual(AnalyticsContentRules.drawingSignature(try imageScene("a")), AnalyticsContentRules.drawingSignature(try imageScene("b")))
        XCTAssertNil(AnalyticsContentRules.drawingSignature(Data("invalid".utf8)))
        XCTAssertNil(AnalyticsContentRules.drawingSignature(nil))
    }

    private func scene(elements: [[String: Any]], state: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["elements": elements, "appState": state])
    }
}
