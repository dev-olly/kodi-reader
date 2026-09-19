import CoreGraphics
import CoreText
import XCTest
@testable import EpubKit

final class PDFBookTests: XCTestCase {
    func testOpensPDFWithMetadataStableIDAndThumbnail() throws {
        let url = try makePDF(title: "Test Document", author: "Kodi Tester", pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try PDFBook(fileURL: url)
        let second = try PDFBook(fileURL: url)
        XCTAssertEqual(first.title, "Test Document")
        XCTAssertEqual(first.author, "Kodi Tester")
        XCTAssertEqual(first.pageCount, 2)
        XCTAssertEqual(first.bookID, second.bookID)
        XCTAssertTrue(first.bookID.hasPrefix("pdf-sha256:"))
        XCTAssertNotNil(first.coverImageData)

        let wrapped = try ReaderDocument(fileURL: url)
        XCTAssertEqual(wrapped.kind, .pdf)
        XCTAssertEqual(wrapped.bookID, first.bookID)
    }

    func testPDFLocatorRoundTripsAndLegacyLocatorDefaultsToEPUB() throws {
        let locator = Locator.pdfPage(
            3,
            ranges: [PDFTextRange(pageIndex: 3, location: 12, length: 8)],
            totalProgression: 0.5,
            text: "Selected"
        )
        let decoded = try JSONDecoder().decode(
            Locator.self,
            from: JSONEncoder().encode(locator)
        )
        XCTAssertEqual(decoded, locator)
        XCTAssertEqual(decoded.kind, .pdf)

        let legacy = Data(#"{"spineIndex":2,"start":{"elementPath":[1],"offset":4}}"#.utf8)
        let old = try JSONDecoder().decode(Locator.self, from: legacy)
        XCTAssertEqual(old.kind, .epub)
        XCTAssertEqual(old.spineIndex, 2)
    }

    func testLibraryImportsPDFWithPDFExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try makePDF(title: "Imported", author: "Tester", pages: 1)
        defer { try? FileManager.default.removeItem(at: source) }
        let book = try PDFBook(fileURL: source)
        let store = LibraryStore(fileURL: root.appendingPathComponent("library.json"))

        let imported = try store.importBook(from: source, bookID: book.bookID, kind: .pdf)
        XCTAssertEqual(imported.pathExtension, "pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))

        var record = BookRecord(
            id: book.bookID,
            title: book.title,
            author: book.author,
            documentKind: .pdf
        )
        record.importedRelativePath = LibraryStore.relativeImportedPath(
            for: book.bookID,
            kind: .pdf
        )
        XCTAssertEqual(store.existingImportedURL(for: record), imported)
    }

    private func makePDF(title: String, author: String, pages: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodi-test-\(UUID().uuidString).pdf")
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: CFDictionary = [
            kCGPDFContextTitle: title,
            kCGPDFContextAuthor: author,
        ] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &box, info) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 700)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "Page \(page + 1) text for selection")
            )
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
