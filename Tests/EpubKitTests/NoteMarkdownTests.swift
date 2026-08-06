import XCTest
@testable import EpubKit

final class NoteMarkdownTests: XCTestCase {
    func testPlainPreviewStripsCommonMarkers() {
        let markdown = "**Bold** and *italic* with a [link](https://example.com) and `code`"
        let preview = NoteMarkdown.plainPreview(of: markdown)
        XCTAssertFalse(preview.contains("**"))
        XCTAssertFalse(preview.contains("["))
        XCTAssertTrue(preview.contains("Bold"))
        XCTAssertTrue(preview.contains("italic"))
        XCTAssertTrue(preview.contains("link"))
        XCTAssertTrue(preview.contains("code"))
    }

    func testWrapAroundSelection() {
        let source = "hello world"
        let range = source.range(of: "world")!
        let result = NoteMarkdown.wrap(source, selection: range, prefix: "**", suffix: "**")
        XCTAssertEqual(result.text, "hello **world**")
        XCTAssertEqual(String(result.text[result.selection]), "**world**")
    }

    func testWrapEmptySelectionInsertsMarkers() {
        let source = "ab"
        let caret = source.index(source.startIndex, offsetBy: 1)
        let result = NoteMarkdown.wrap(source, selection: caret..<caret, prefix: "**", suffix: "**")
        XCTAssertEqual(result.text, "a****b")
        XCTAssertEqual(result.selection.lowerBound, result.text.index(result.text.startIndex, offsetBy: 3))
    }

    func testPrefixBulletLines() {
        let source = "one\ntwo"
        let range = source.startIndex..<source.endIndex
        let result = NoteMarkdown.prefixLines(source, selection: range, marker: "- ")
        XCTAssertEqual(result.text, "- one\n- two")
    }

    func testPrefixNumberedLines() {
        let source = "one\ntwo"
        let range = source.startIndex..<source.endIndex
        let result = NoteMarkdown.prefixLines(source, selection: range, marker: "1. ")
        XCTAssertEqual(result.text, "1. one\n2. two")
    }

    func testExportDocumentShape() {
        let annotation = Annotation(
            locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [0], offset: 0)),
            text: "quoted passage",
            note: "My **note**",
            chapterTitle: "Chapter 1"
        )
        let markdown = NoteMarkdown.exportDocument(
            bookTitle: "Frankenstein",
            annotations: [annotation]
        )
        XCTAssertTrue(markdown.contains("# Notes — Frankenstein"))
        XCTAssertTrue(markdown.contains("## quoted passage"))
        XCTAssertTrue(markdown.contains("*Chapter 1*"))
        XCTAssertTrue(markdown.contains("My **note**"))
        XCTAssertTrue(markdown.contains("---"))
    }

    func testExportSkipsHighlightsWithoutNotes() {
        let bare = Annotation(
            locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)),
            text: "no note here"
        )
        let markdown = NoteMarkdown.exportDocument(bookTitle: "Book", annotations: [bare])
        XCTAssertTrue(markdown.contains("_No notes yet._"))
        XCTAssertFalse(markdown.contains("no note here"))
    }

    func testAnnotationDecodesWithoutAnchorStatus() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "locator": {
            "spineIndex": 0,
            "start": { "elementPath": [1], "offset": 0 }
          },
          "text": "quote",
          "note": "hello",
          "color": "yellow",
          "createdAt": 0,
          "modifiedAt": 0
        }
        """.data(using: .utf8)!

        let annotation = try JSONDecoder().decode(Annotation.self, from: json)
        XCTAssertEqual(annotation.anchorStatus, .unknown)
        XCTAssertEqual(annotation.note, "hello")
        XCTAssertEqual(annotation.plainNotePreview, "hello")
    }

    func testLibraryStoreMigratesV1ToV2() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-v1-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let v1 = """
        {
          "version": 1,
          "books": {
            "book-1": {
              "id": "book-1",
              "title": "Test",
              "author": "Author",
              "lastOpenedAt": 0,
              "progress": 0,
              "annotations": [
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "locator": {
                    "spineIndex": 0,
                    "start": { "elementPath": [0], "offset": 0 }
                  },
                  "text": "quote",
                  "note": "old note",
                  "color": "yellow",
                  "createdAt": 0,
                  "modifiedAt": 0
                }
              ],
              "bookmarks": []
            }
          }
        }
        """.data(using: .utf8)!
        try v1.write(to: url)

        let store = LibraryStore(fileURL: url)
        XCTAssertEqual(store.schemaVersion, LibraryStore.currentVersion)
        let record = try XCTUnwrap(store.record(for: "book-1"))
        XCTAssertEqual(record.annotations.count, 1)
        XCTAssertEqual(record.annotations[0].anchorStatus, .unknown)
        XCTAssertEqual(record.annotations[0].note, "old note")

        store.flush()
        let reloaded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(reloaded?["version"] as? Int, 2)
    }
}
