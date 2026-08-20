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

    func testDeleteAllScenesRemovesBookFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drawings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DrawingStore(rootDirectory: root)
        let first = UUID()
        let second = UUID()
        store.saveScene(Data("{}".utf8), bookID: "Book One", annotationID: first)
        store.saveScene(Data("{}".utf8), bookID: "Book One", annotationID: second)
        store.flush()

        store.deleteAllScenes(bookID: "Book One")
        XCTAssertNil(store.loadScene(bookID: "Book One", annotationID: first))
        XCTAssertNil(store.loadScene(bookID: "Book One", annotationID: second))
        let folder = store.drawingsDirectory.appendingPathComponent(
            LibraryStore.sanitizedFileName(for: "Book One")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
