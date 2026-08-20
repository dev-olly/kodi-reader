import XCTest
@testable import EpubKit

final class LibraryImportTests: XCTestCase {
    func testImportBookCopiesIntoBooksDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let libraryURL = root.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: libraryURL)

        let source = SampleBooks.url(SampleBooks.frankenstein)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Missing sample. Run Scripts/fetch-samples.sh.")
        }
        let imported = try store.importBook(from: source, bookID: "urn:example:frankenstein")

        XCTAssertTrue(store.isImportedURL(imported))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertEqual(
            imported.lastPathComponent,
            LibraryStore.sanitizedFileName(for: "urn:example:frankenstein") + ".epub"
        )

        // Re-import from the copy is a no-op path-wise.
        let again = try store.importBook(from: imported, bookID: "urn:example:frankenstein")
        XCTAssertEqual(again.path, imported.path)

        var record = BookRecord(id: "urn:example:frankenstein", title: "F", author: "A")
        record.importedRelativePath = LibraryStore.relativeImportedPath(for: record.id)
        XCTAssertEqual(store.existingImportedURL(for: record)?.path, imported.path)
    }

    func testBookRecordDecodesWithoutImportedRelativePath() throws {
        let json = """
        {
          "id": "book-1",
          "title": "Test",
          "author": "Author",
          "lastOpenedAt": 0,
          "progress": 0,
          "annotations": [],
          "bookmarks": []
        }
        """.data(using: .utf8)!
        let record = try JSONDecoder().decode(BookRecord.self, from: json)
        XCTAssertNil(record.importedRelativePath)
        XCTAssertNil(record.chatMessages)
        XCTAssertEqual(record.conversation, [])
    }
}
