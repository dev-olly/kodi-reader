import XCTest
@testable import EpubKit

final class ArticleEPUBBuilderTests: XCTestCase {
    /// 1×1 PNG so image inlining can be tested without the network.
    private static let pngDataURL =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    func testNormalizedURLAddsHTTPS() throws {
        let url = try XCTUnwrap(WebPageURL.normalized(from: "example.com/post"))
        XCTAssertEqual(url.absoluteString, "https://example.com/post")
    }

    func testNormalizedURLRejectsNonWebSchemes() {
        XCTAssertNil(WebPageURL.normalized(from: "file:///tmp/page.html"))
        XCTAssertNil(WebPageURL.normalized(from: "javascript:alert(1)"))
        XCTAssertNil(WebPageURL.normalized(from: ""))
    }

    func testIdentifierIsStableAcrossEquivalentURLs() {
        let a = URL(string: "https://Example.com/Post/")!
        let b = URL(string: "https://example.com/Post#section")!
        XCTAssertEqual(WebPageURL.identifier(for: a), WebPageURL.identifier(for: b))
        XCTAssertEqual(WebPageURL.identifier(for: a), "web:https://example.com/Post")
    }

    func testBuildsReadableSingleChapterEPUB() async throws {
        let source = URL(string: "https://example.com/articles/widget")!
        let article = ArticleContent(
            title: "Widgets Considered",
            byline: "Ada Lovelace",
            sourceURL: source,
            contentHTML: """
            <p>A widget is a small mechanical device.</p>
            <img src="\(Self.pngDataURL)" alt="dot">
            <br>
            <p>They are useful AT&T times.</p>
            """,
            language: "en"
        )

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("article-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await ArticleEPUBBuilder.build(article, to: destination)

        let book = try EPUBBook(fileURL: destination)
        XCTAssertEqual(book.bookID, WebPageURL.identifier(for: source))
        XCTAssertEqual(book.title, "Widgets Considered")
        XCTAssertEqual(book.author, "Ada Lovelace")
        XCTAssertEqual(book.publication.readingOrder.count, 1)

        let chapter = try XCTUnwrap(book.publication.readingOrder.first)
        let html = try book.container.string(at: chapter.path)
        XCTAssertTrue(html.contains("small mechanical device"))
        XCTAssertTrue(html.contains("AT&amp;T"))
        XCTAssertTrue(html.contains("<br/>") || html.contains("<br />"))

        let imageItems = book.publication.manifest.values.filter { $0.mediaType.hasPrefix("image/") }
        XCTAssertEqual(imageItems.count, 1)
        let imagePath = try XCTUnwrap(imageItems.first?.path)
        let imageData = try book.data(at: imagePath)
        XCTAssertGreaterThan(imageData.count, 16)
        XCTAssertEqual(Array(imageData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testSameURLProducesTheSameBookID() async throws {
        let source = URL(string: "https://example.com/same-article")!
        let article = ArticleContent(
            title: "Same",
            sourceURL: source,
            contentHTML: "<p>Hello.</p>"
        )

        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("article-a-\(UUID().uuidString).epub")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("article-b-\(UUID().uuidString).epub")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        try await ArticleEPUBBuilder.build(article, to: firstURL)
        try await ArticleEPUBBuilder.build(article, to: secondURL)

        let first = try EPUBBook(fileURL: firstURL)
        let second = try EPUBBook(fileURL: secondURL)
        XCTAssertEqual(first.bookID, second.bookID)
        XCTAssertEqual(first.bookID, WebPageURL.identifier(for: source))
    }

    func testLocatorRoundTripsOnAFrozenArticle() async throws {
        let source = URL(string: "https://example.com/notes")!
        let article = ArticleContent(
            title: "Notes",
            sourceURL: source,
            contentHTML: "<p>Highlight this sentence.</p>"
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("article-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await ArticleEPUBBuilder.build(article, to: destination)
        let book = try EPUBBook(fileURL: destination)
        XCTAssertEqual(book.publication.readingOrder.count, 1)

        let locator = Locator(
            spineIndex: 0,
            start: TextPosition(elementPath: [1, 0], offset: 0),
            end: TextPosition(elementPath: [1, 0], offset: 24),
            text: "Highlight this sentence."
        )
        let annotation = Annotation(locator: locator, text: "Highlight this sentence.")
        var record = BookRecord(
            id: book.bookID,
            title: book.title,
            author: book.author,
            sourceURL: source
        )
        record.annotations = [annotation]
        record.position = locator

        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(BookRecord.self, from: encoded)
        XCTAssertEqual(decoded.sourceURL, source)
        XCTAssertEqual(decoded.annotations.first?.locator, locator)
        XCTAssertEqual(decoded.annotations.first?.text, "Highlight this sentence.")
        XCTAssertTrue(decoded.isWebDocument)
    }

    func testEmptyArticleThrows() async {
        let article = ArticleContent(
            title: "Empty",
            sourceURL: URL(string: "https://example.com/empty")!,
            contentHTML: "   "
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("article-\(UUID().uuidString).epub")
        do {
            try await ArticleEPUBBuilder.build(article, to: destination)
            XCTFail("Expected emptyArticle")
        } catch let error as ArticleError {
            XCTAssertEqual(error, .emptyArticle)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
