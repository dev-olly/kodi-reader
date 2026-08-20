import XCTest
@testable import EpubKit

final class DrawingStoreTests: XCTestCase {
    func testSaveLoadDeleteRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drawings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DrawingStore(rootDirectory: root)
        let annotationID = UUID()
        let scene = Data(#"{"type":"excalidraw","elements":[{"id":"a"}]}"#.utf8)

        store.saveScene(scene, bookID: "urn:book:1", annotationID: annotationID)
        store.flush()

        let loaded = try XCTUnwrap(store.loadScene(bookID: "urn:book:1", annotationID: annotationID))
        XCTAssertEqual(loaded, scene)

        store.deleteScene(bookID: "urn:book:1", annotationID: annotationID)
        XCTAssertNil(store.loadScene(bookID: "urn:book:1", annotationID: annotationID))
    }
