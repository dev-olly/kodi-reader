import XCTest
@testable import EpubKit

final class ReadingMarkerTests: XCTestCase {
    func testMovingAndRemovingMarkerPreservesPageBookmarks() throws {
        let pageBookmark = Bookmark(locator: .startOfBook(), chapterTitle: "Beginning")
        var record = BookRecord(id: "book", title: "Book", author: "Author", bookmarks: [pageBookmark])
        let first = Bookmark(
            locator: Locator(spineIndex: 2, start: TextPosition(elementPath: [1, 0], offset: 14)),
            chapterTitle: "Chapter 3",
            excerpt: "Stopped here"
        )
        record.readingMarker = first
        let firstMarker = try XCTUnwrap(record.readingMarker)
        XCTAssertTrue(firstMarker.isReadingMarker)
        XCTAssertEqual(firstMarker.id, Bookmark.readingMarkerID)
        XCTAssertEqual(firstMarker.locator, first.locator)
        XCTAssertEqual(record.pageBookmarks, [pageBookmark])

        let moved = Bookmark(locator: .pdfPage(7), chapterTitle: "Page 8")
        record.readingMarker = moved
        XCTAssertEqual(record.readingMarker?.id, firstMarker.id)
        XCTAssertEqual(record.readingMarker?.locator, moved.locator)
        XCTAssertEqual(record.bookmarks.filter(\.isReadingMarker).count, 1)
        XCTAssertEqual(record.pageBookmarks, [pageBookmark])

        record.readingMarker = nil
        XCTAssertNil(record.readingMarker)
        XCTAssertEqual(record.bookmarks, [pageBookmark])
    }

    func testMarkerPersistsIndependentlyOfProgressForEPUBAndPDF() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reading-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: library)
        let markers = [
            Locator(spineIndex: 2, start: TextPosition(elementPath: [1, 0], offset: 14), totalProgression: 0.3),
            Locator.pdfPage(3, ranges: [PDFTextRange(pageIndex: 3, location: 12, length: 1)], totalProgression: 0.3),
        ]
        for marker in markers {
            let id = marker.kind.rawValue
            var record = BookRecord(id: id, title: "Book", author: "Author", documentKind: marker.kind)
            record.readingMarker = Bookmark(locator: marker, chapterTitle: "Stopping point")
            store.upsert(record)
            try store.checkpoint()
            store.update(id) {
                $0.position = marker.kind == .pdf ? .pdfPage(9) : .startOfBook()
                $0.progress = 0.9
            }
            try store.checkpoint()
            let saved = try XCTUnwrap(LibraryStore(fileURL: library).record(for: id))
            XCTAssertEqual(saved.readingMarker?.locator, marker)
            XCTAssertEqual(saved.progress, 0.9)
            XCTAssertNotEqual(saved.position, saved.readingMarker?.locator)
            XCTAssertTrue(saved.pageBookmarks.isEmpty)
        }
    }

    func testLegacyBookmarksDecodeWithoutCreatingReadingMarker() throws {
        let legacy = Data(#"{"id":"book","title":"Book","author":"Author","lastOpenedAt":0,"progress":0,"bookmarks":[{"id":"00000000-0000-4000-8000-000000000001","locator":{"spineIndex":2,"start":{"elementPath":[1],"offset":4}},"chapterTitle":"Chapter 3","createdAt":0}]}"#.utf8)
        let record = try JSONDecoder().decode(BookRecord.self, from: legacy)
        XCTAssertNil(record.readingMarker)
        XCTAssertEqual(record.pageBookmarks.count, 1)
        XCTAssertFalse(record.pageBookmarks[0].isReadingMarker)
    }

    func testReadingMarkerUsesExistingBookmarkWireFormat() throws {
        var record = BookRecord(id: "book", title: "Book", author: "Author")
        record.readingMarker = Bookmark(locator: .startOfBook(), excerpt: "A stopping point")
        let encoded = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["readingMarker"])
        let bookmarkData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["bookmarks"]))
        let bookmarks = try JSONDecoder().decode([Bookmark].self, from: bookmarkData)
        XCTAssertEqual(bookmarks, [try XCTUnwrap(record.readingMarker)])
        XCTAssertEqual(try JSONDecoder().decode(BookRecord.self, from: encoded).readingMarker, record.readingMarker)
    }
}
