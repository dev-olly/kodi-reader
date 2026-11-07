import XCTest
@testable import EpubKit

final class LibraryQueryTests: XCTestCase {
    func testSearchMatchesAllWordsAcrossTitleAndAuthorIgnoringCaseAndAccents() {
        let books = [
            book("solitude", title: "One Hundred Years of Solitude", author: "Gabriel García Márquez"),
            book("other", title: "Solitude", author: "Another writer"),
        ]
        XCTAssertEqual(
            LibraryQuery(searchText: "  GARCIA\n solitude  ").apply(to: books).map(\.id),
            ["solitude"]
        )
        XCTAssertTrue(LibraryQuery(searchText: "garcia missing").apply(to: books).isEmpty)
        XCTAssertEqual(LibraryQuery(searchText: " \n\t ").apply(to: books).count, 2)
    }

    func testTitleSortUsesNaturalAlphabeticalOrderInBothDirections() {
        let books = [book("10", title: "Book 10"), book("2", title: "Book 2"), book("1", title: "Book 1")]
        XCTAssertEqual(
            LibraryQuery(sort: .title, ascending: true).apply(to: books).map(\.id),
            ["1", "2", "10"]
        )
        XCTAssertEqual(
            LibraryQuery(sort: .title, ascending: false).apply(to: books).map(\.id),
            ["10", "2", "1"]
        )
    }

    func testDateAddedAndDateReadHaveIndependentAscendingAndDescendingOrders() {
        let books = [
            book("first", added: 10, read: 30),
            book("second", added: 20, read: 10),
            book("third", added: 30, read: 20),
        ]
        XCTAssertEqual(LibraryQuery(sort: .dateAdded).apply(to: books).map(\.id), ["third", "second", "first"])
        XCTAssertEqual(LibraryQuery(sort: .dateAdded, ascending: true).apply(to: books).map(\.id), ["first", "second", "third"])
        XCTAssertEqual(LibraryQuery().apply(to: books).map(\.id), ["first", "third", "second"])
        XCTAssertEqual(LibraryQuery(sort: .dateRead, ascending: true).apply(to: books).map(\.id), ["second", "third", "first"])
    }

    func testEqualDatesUseTitleThenIDForStableOrder() {
        let books = [book("z", title: "Bravo"), book("b", title: "Alpha"), book("a", title: "Alpha")]
        for sort in [LibrarySort.dateAdded, .dateRead] {
            for ascending in [false, true] {
                let query = LibraryQuery(sort: sort, ascending: ascending)
                XCTAssertEqual(query.apply(to: books).map(\.id), ["a", "b", "z"])
                XCTAssertEqual(query.apply(to: Array(books.reversed())).map(\.id), ["a", "b", "z"])
            }
        }
        XCTAssertEqual(LibraryQuery(sort: .title, ascending: true).apply(to: books).map(\.id), ["a", "b", "z"])
    }

    func testUnknownAddedDatesStayLastInEitherDirection() {
        var unknownBravo = book("unknown-bravo", title: "Bravo")
        unknownBravo.addedAt = nil
        var unknownAlpha = book("unknown-alpha", title: "Alpha")
        unknownAlpha.addedAt = nil
        let books = [unknownBravo, book("older", added: 10), unknownAlpha, book("newer", added: 20)]
        XCTAssertEqual(
            LibraryQuery(sort: .dateAdded).apply(to: books).map(\.id),
            ["newer", "older", "unknown-alpha", "unknown-bravo"]
        )
        XCTAssertEqual(
            LibraryQuery(sort: .dateAdded, ascending: true).apply(to: books).map(\.id),
            ["older", "newer", "unknown-alpha", "unknown-bravo"]
        )
    }

    func testReadingFiltersPartitionProgressAtTheDisplayedBoundaries() {
        let books = [
            book("zero", progress: 0),
            book("unread-boundary", progress: 0.001),
            book("started", progress: 0.00101),
            book("almost-finished", progress: 0.98999),
            book("finished-boundary", progress: 0.99),
            book("complete", progress: 1),
        ]
        XCTAssertEqual(Set(LibraryQuery(filter: .unread).apply(to: books).map(\.id)), ["zero", "unread-boundary"])
        XCTAssertEqual(Set(LibraryQuery(filter: .inProgress).apply(to: books).map(\.id)), ["started", "almost-finished"])
        XCTAssertEqual(Set(LibraryQuery(filter: .finished).apply(to: books).map(\.id)), ["finished-boundary", "complete"])
        XCTAssertEqual(LibraryQuery(filter: .all).apply(to: books).count, books.count)
    }

    func testRecentlyReadIncludesSevenDayBoundaryAndExcludesUnreadAndFutureDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12)))
        // This window crosses the autumn daylight-saving change.
        let cutoff = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: now))
        var boundary = book("boundary", progress: 0.2)
        boundary.lastOpenedAt = cutoff
        var old = book("old", progress: 0.2)
        old.lastOpenedAt = cutoff.addingTimeInterval(-1)
        var future = book("future", progress: 0.2)
        future.lastOpenedAt = now.addingTimeInterval(1)
        var unread = book("unread", progress: 0)
        unread.lastOpenedAt = now
        var finished = book("finished", progress: 1)
        finished.lastOpenedAt = now

        XCTAssertEqual(
            LibraryQuery(filter: .recentlyRead).apply(to: [old, unread, boundary, future, finished], now: now, calendar: calendar).map(\.id),
            ["finished", "boundary"]
        )
    }

    func testSearchAndReadingFilterCombineBeforeSorting() {
        let books = [
            book("later", title: "Swift Systems", author: "A writer", added: 30, progress: 0.4),
            book("earlier", title: "Swift Fundamentals", author: "A writer", added: 10, progress: 0.1),
            book("unread", title: "Swift Reference", added: 40),
            book("other", title: "Another language", added: 20, progress: 0.3),
        ]
        XCTAssertEqual(
            LibraryQuery(searchText: "swift writer", sort: .dateAdded, filter: .inProgress).apply(to: books).map(\.id),
            ["later", "earlier"]
        )
    }

    private func book(
        _ id: String,
        title: String = "Book",
        author: String = "Author",
        added: TimeInterval = 0,
        read: TimeInterval = 0,
        progress: Double = 0
    ) -> BookRecord {
        var record = BookRecord(id: id, title: title, author: author, lastOpenedAt: Date(timeIntervalSince1970: read), progress: progress)
        record.addedAt = Date(timeIntervalSince1970: added)
        return record
    }
}
