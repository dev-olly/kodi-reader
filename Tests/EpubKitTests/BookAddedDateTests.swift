import XCTest
@testable import EpubKit

final class BookAddedDateTests: XCTestCase {
    func testLegacyRecordKeepsUnknownImportDate() throws {
        let data = Data("""
        {"id":"legacy","title":"Legacy","author":"Author","lastOpenedAt":1000}
        """.utf8)
        var record = try JSONDecoder().decode(BookRecord.self, from: data)
        XCTAssertNil(record.addedAt)
        record.lastOpenedAt = Date(timeIntervalSinceReferenceDate: 2000)
        let reloaded = try JSONDecoder().decode(BookRecord.self, from: JSONEncoder().encode(record))
        XCTAssertNil(reloaded.addedAt, "Opening an old book must not invent an import date")
    }

    func testImportDateSurvivesReopenRenameAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: path)
        let added = Date(timeIntervalSinceReferenceDate: 1000)
        let record = BookRecord(id: "book", title: "Original", author: "Author", addedAt: added)
        store.upsert(record)
        try store.updateAndFlush(record.id) { $0.lastOpenedAt = Date(timeIntervalSinceReferenceDate: 2000) }
        try store.renameBook(record.id, to: "Renamed")
        let reloaded = try XCTUnwrap(LibraryStore(fileURL: path).record(for: record.id))
        XCTAssertEqual(reloaded.addedAt, added)
        XCTAssertEqual(reloaded.lastOpenedAt, Date(timeIntervalSinceReferenceDate: 2000))
        XCTAssertEqual(reloaded.title, "Renamed")
    }

    func testMetadataConflictKeepsEarliestKnownImportDate() throws {
        let early = Date(timeIntervalSinceReferenceDate: 1000)
        let later = Date(timeIntervalSinceReferenceDate: 2000)
        let local = try metadata(title: "Local", addedAt: early, modifiedAt: 1)
        let remote = try metadata(title: "Remote", addedAt: later, modifiedAt: 2)
        let result = try XCTUnwrap(SyncMerge.resolve(local: local, remote: remote, ancestor: nil).first)
        let book = try result.value(SyncedBook.self)
        XCTAssertEqual(book.title, "Remote")
        XCTAssertEqual(book.addedAt, early)
    }

    func testOlderClientMetadataEditCannotClearKnownImportDate() throws {
        let added = Date(timeIntervalSinceReferenceDate: 1000)
        let ancestor = try metadata(title: "Original", addedAt: added, modifiedAt: 1)
        let remote = try metadata(title: "Renamed by older client", addedAt: nil, modifiedAt: 2)
        let result = try XCTUnwrap(SyncMerge.resolve(local: ancestor, remote: remote, ancestor: ancestor).first)
        let book = try result.value(SyncedBook.self)
        XCTAssertEqual(book.title, "Renamed by older client")
        XCTAssertEqual(book.addedAt, added)
    }

    func testLegacySyncMetadataHasUnknownImportDate() throws {
        let data = Data("""
        {"title":"Legacy","author":"Author","kind":"epub"}
        """.utf8)
        let book = try JSONDecoder().decode(SyncedBook.self, from: data)
        XCTAssertNil(book.addedAt)
    }

    private func metadata(title: String, addedAt: Date?, modifiedAt: TimeInterval) throws -> SyncEntity {
        let book = SyncedBook(title: title, author: "Author", kind: .epub, sourceURL: nil, file: nil, addedAt: addedAt)
        return SyncEntity(bookID: "book", kind: .book, key: "metadata", body: try SyncCoding.encode(book),
                          modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedAt), deviceID: title)
    }
}
