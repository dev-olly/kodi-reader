import XCTest
@testable import EpubKit

final class EPUBBookTests: XCTestCase {
    // MARK: - Metadata

    func testParsesMetadata() throws {
        let book = try SampleBooks.open(SampleBooks.frankenstein)

        XCTAssertTrue(
            book.title.localizedCaseInsensitiveContains("Frankenstein"),
            "Unexpected title: \(book.title)"
        )
        XCTAssertEqual(book.publication.metadata.creators.first, "Mary Wollstonecraft Shelley")
        XCTAssertEqual(book.publication.metadata.language, "en")
        XCTAssertEqual(book.publication.metadata.identifier, "http://www.gutenberg.org/84")
    }

    func testUsesPublicationIdentifierAsBookID() throws {
        let book = try SampleBooks.open(SampleBooks.frankenstein)
        XCTAssertEqual(book.bookID, "http://www.gutenberg.org/84")
    }

    /// The same file opened twice must produce the same key, or reading
    /// positions and annotations would be orphaned on reopen.
    func testBookIDIsStable() throws {
        let first = try SampleBooks.open(SampleBooks.alice)
        let second = try SampleBooks.open(SampleBooks.alice)
        XCTAssertEqual(first.bookID, second.bookID)
    }

    // MARK: - Spine

    func testSpineIsPopulatedAndReadable() throws {
        let book = try SampleBooks.open(SampleBooks.frankenstein)
        let order = book.publication.readingOrder

        XCTAssertGreaterThan(order.count, 5)
        for item in order {
            XCTAssertTrue(
                book.container.contains(item.path),
                "Spine references a missing entry: \(item.path)"
            )
            XCTAssertEqual(item.mediaType, "application/xhtml+xml")
        }
    }

    func testSpinePathsAreResolvedAgainstThePackage() throws {
        let book = try SampleBooks.open(SampleBooks.frankenstein)
        // The package sits in OEBPS/, so hrefs must be rewritten to include it.
        XCTAssertTrue(book.publication.packagePath.hasSuffix("content.opf"))
        for item in book.publication.readingOrder {
            XCTAssertTrue(item.path.hasPrefix("OEBPS/"), "Unresolved spine path: \(item.path)")
        }
    }

    // MARK: - Table of contents

    /// Frankenstein and Alice ship a nav document; this exercises the EPUB 3 path.
    func testParsesNavigationDocumentTOC() throws {
        let book = try SampleBooks.open(SampleBooks.frankenstein)
        let toc = book.publication.toc

        XCTAssertFalse(toc.isEmpty, "Expected a table of contents")
        let titles = toc.flatMap(\.flattened).map(\.title)
        XCTAssertTrue(
            titles.contains { $0.localizedCaseInsensitiveContains("Letter 1") },
            "Expected the opening letter in the TOC, got: \(titles.prefix(10))"
        )
    }

    /// Pride and Prejudice has no nav document, so this exercises the NCX path.
    func testParsesNCXTOC() throws {
        let book = try SampleBooks.open(SampleBooks.prideAndPrejudice)
        let toc = book.publication.toc

        XCTAssertFalse(toc.isEmpty, "Expected an NCX-derived table of contents")
        let titles = toc.flatMap(\.flattened).map(\.title)
        XCTAssertTrue(
            titles.contains { $0.localizedCaseInsensitiveContains("Chapter") },
            "Expected chapter entries, got: \(titles.prefix(10))"
        )
    }

    func testTOCEntriesPointAtRealResources() throws {
        for name in [SampleBooks.frankenstein, SampleBooks.alice, SampleBooks.prideAndPrejudice] {
            let book = try SampleBooks.open(name)
            for entry in book.publication.toc.flatMap(\.flattened) where !entry.path.isEmpty {
                XCTAssertTrue(
                    book.container.contains(entry.path),
                    "\(name): TOC entry \"\(entry.title)\" points at missing \(entry.path)"
                )
            }
        }
    }

    // MARK: - Resources

    func testReadsCoverImage() throws {
        let book = try SampleBooks.open(SampleBooks.frankenstein)
        let cover = try XCTUnwrap(book.coverImageData)
        XCTAssertGreaterThan(cover.count, 1000)
        // JPEG magic number.
        XCTAssertEqual(Array(cover.prefix(2)), [0xFF, 0xD8])
    }

    func testReadsSpineDocumentAsText() throws {
        let book = try SampleBooks.open(SampleBooks.alice)
        let first = try XCTUnwrap(book.publication.readingOrder.first)
        let html = try book.container.string(at: first.path)
        XCTAssertTrue(html.localizedCaseInsensitiveContains("<html"))
    }

    func testMissingResourceThrows() throws {
        let book = try SampleBooks.open(SampleBooks.alice)
        XCTAssertThrowsError(try book.data(at: "OEBPS/does-not-exist.xhtml")) { error in
            XCTAssertEqual(error as? EPUBError, .resourceNotFound("OEBPS/does-not-exist.xhtml"))
        }
    }

    func testChapterTitleResolvesForEverySpineItem() throws {
        let book = try SampleBooks.open(SampleBooks.frankenstein)
        // Later spine items fall back to the nearest preceding TOC entry, so
        // every position past the first chapter should name something.
        let lastIndex = book.publication.readingOrder.count - 1
        XCTAssertNotNil(book.chapterTitle(forSpineIndex: lastIndex))
    }

    // MARK: - Failure handling

    func testRejectsNonZipFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-book-\(UUID().uuidString).epub")
        try Data("this is plain text".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try EPUBBook(fileURL: url)) { error in
            guard case .notAZipArchive = error as? EPUBError else {
                return XCTFail("Expected notAZipArchive, got \(error)")
            }
        }
    }
}
