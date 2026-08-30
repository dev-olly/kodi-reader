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

    func testFenceCodeBlockWrapsSelection() {
        let source = "before print() after"
        let range = source.range(of: "print()")!
        let result = NoteMarkdown.fenceCodeBlock(source, selection: range)
        XCTAssertEqual(result.text, "before ```\nprint()\n``` after")
        XCTAssertEqual(String(result.text[result.selection]), "```\nprint()\n```")
    }

    func testFenceCodeBlockEmptyCaret() {
        let source = "ab"
        let caret = source.index(source.startIndex, offsetBy: 1)
        let result = NoteMarkdown.fenceCodeBlock(source, selection: caret..<caret)
        XCTAssertEqual(result.text, "a```\n\n```b")
        let expectedCaret = result.text.index(result.text.startIndex, offsetBy: 5) // after "a```\n"
        XCTAssertEqual(result.selection, expectedCaret..<expectedCaret)
    }

    func testPreviewSegmentsSplitsProseAndCode() {
        let markdown = "I can\n```\nprint(\"hi\")\n```\ndone"
        let segments = NoteMarkdown.previewSegments(of: markdown)
        XCTAssertEqual(
            segments,
            [
                .prose("I can\n"),
                .code("print(\"hi\")"),
                .prose("done"),
            ]
        )
    }

    func testPreviewSegmentsEmptyFenceBody() {
        let markdown = "before\n```\n\n```\nafter"
        let segments = NoteMarkdown.previewSegments(of: markdown)
        XCTAssertEqual(
            segments,
            [
                .prose("before\n"),
                .code(""),
                .prose("after"),
            ]
        )
    }

    func testPreviewSegmentsLanguageTag() {
        let markdown = "```swift\nlet x = 1\n```"
        XCTAssertEqual(NoteMarkdown.previewSegments(of: markdown), [.code("let x = 1")])
    }

    func testPreviewBlocksScreenshotSample() {
        let markdown = """
        The **opening** line.

        ```
        print("hello")
        ```

        - I know what kind of man you are
        - I knew you could do it

        1. baby
        2. i love you
        """
        XCTAssertEqual(
            NoteMarkdown.previewBlocks(of: markdown),
            [
                .paragraph("The **opening** line."),
                .code("print(\"hello\")"),
                .unorderedList([
                    "I know what kind of man you are",
                    "I knew you could do it",
                ]),
                .orderedList([
                    "baby",
                    "i love you",
                ]),
            ]
        )
    }

    func testPreviewBlocksParsesGFMTable() {
        let markdown = """
        | Weak | Strong |
        | --- | ---: |
        | Blame circumstances | Study circumstances |
        | Consume | Build |
        """
        XCTAssertEqual(
            NoteMarkdown.previewBlocks(of: markdown),
            [
                .table(
                    header: ["Weak", "Strong"],
                    rows: [
                        ["Blame circumstances", "Study circumstances"],
                        ["Consume", "Build"],
                    ],
                    alignments: [.leading, .trailing]
                ),
            ]
        )
    }

    func testPreviewBlocksParsesRaggedTableSeparator() {
        let markdown = """
        | Weak dependence | Rockefeller's self-reliance |
        | ---------------------------- |
        | "Someone should help me." | "What can I do?" |
        """
        XCTAssertEqual(
            NoteMarkdown.previewBlocks(of: markdown),
            [
                .table(
                    header: ["Weak dependence", "Rockefeller's self-reliance"],
                    rows: [
                        ["\"Someone should help me.\"", "\"What can I do?\""],
                    ],
                    alignments: [.leading, .leading]
                ),
            ]
        )
    }

    func testPreviewBlocksKeepsLonePipeLineAsParagraph() {
        XCTAssertEqual(
            NoteMarkdown.previewBlocks(of: "| just a pipe |"),
            [.paragraph("| just a pipe |")]
        )
    }

    func testInsertTablePlacesCaretInFirstBodyCell() {
        let source = "ab"
        let caret = source.index(source.startIndex, offsetBy: 1)
        let result = NoteMarkdown.insertTable(source, selection: caret..<caret)
        XCTAssertEqual(
            result.text,
            "a| Column | Column |\n| --- | --- |\n|  |  |b"
        )
        let expected = "| Column | Column |\n| --- | --- |\n| ".count + 1
        let expectedCaret = result.text.index(result.text.startIndex, offsetBy: expected)
        XCTAssertEqual(result.selection, expectedCaret..<expectedCaret)
    }

    func testExportDocumentShape() {
        let annotation = Annotation(
            locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [0], offset: 0)),
            text: "quoted passage\nsecond line",
            note: "My **note**",
            chapterTitle: "Chapter 1"
        )
        let markdown = NoteMarkdown.exportDocument(
            bookTitle: "Frankenstein",
            author: "Mary Wollstonecraft Shelley",
            annotations: [annotation]
        )
        XCTAssertTrue(markdown.contains("# Notes — Frankenstein"))
        XCTAssertTrue(markdown.contains("Mary Wollstonecraft Shelley"))
        XCTAssertTrue(markdown.contains("### Chapter 1"))
        XCTAssertTrue(markdown.contains("> quoted passage"))
        XCTAssertTrue(markdown.contains("> second line"))
        XCTAssertTrue(
            markdown.contains(
                "*— Chapter 1, Mary Wollstonecraft Shelley, Frankenstein*"
            )
        )
        XCTAssertTrue(markdown.contains("My **note**"))
        XCTAssertTrue(markdown.contains("---"))
        // Quote is source material, not the section heading.
        XCTAssertFalse(markdown.contains("## quoted passage"))
    }

    func testExportSkipsHighlightsWithoutNotes() {
        let bare = Annotation(
            locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)),
            text: "no note here"
        )
        let markdown = NoteMarkdown.exportDocument(
            bookTitle: "Book",
            author: "Author",
            annotations: [bare]
        )
        XCTAssertTrue(markdown.contains("_No notes yet._"))
        XCTAssertFalse(markdown.contains("no note here"))
    }

    func testExportUsesUntitledSectionWhenChapterMissing() {
        let annotation = Annotation(
            locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)),
            text: "a quote",
            note: "body"
        )
        let markdown = NoteMarkdown.exportDocument(
            bookTitle: "Book",
            author: "Author",
            annotations: [annotation]
        )
        XCTAssertTrue(markdown.contains("### Untitled section"))
        XCTAssertTrue(markdown.contains("*— Untitled section, Author, Book*"))
    }

    func testBlockquotePrefixesEachLine() {
        XCTAssertEqual(NoteMarkdown.blockquote("one\n\ntwo"), "> one\n>\n> two")
        XCTAssertEqual(NoteMarkdown.blockquote("  "), ">")
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
        XCTAssertFalse(annotation.hasDrawing)
        XCTAssertTrue(annotation.hasNote)
        XCTAssertTrue(annotation.hasContent)
    }

    func testAnnotationDecodesWithoutHasDrawing() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "locator": {
            "spineIndex": 0,
            "start": { "elementPath": [1], "offset": 0 }
          },
          "text": "quote",
          "color": "yellow",
          "createdAt": 0,
          "modifiedAt": 0
        }
        """.data(using: .utf8)!

        let annotation = try JSONDecoder().decode(Annotation.self, from: json)
        XCTAssertFalse(annotation.hasDrawing)
        XCTAssertFalse(annotation.hasNote)
        XCTAssertFalse(annotation.hasContent)
    }

    func testDrawingOnlyAnnotationHasContentAndNoteDot() {
        let annotation = Annotation(
            locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)),
            text: "quote",
            hasDrawing: true
        )
        XCTAssertFalse(annotation.hasNote)
        XCTAssertTrue(annotation.hasContent)
        XCTAssertEqual(annotation.javaScriptPayload["hasNote"] as? Bool, true)
        XCTAssertNil(annotation.javaScriptPayload["note"])
    }

    func testExportIncludesDrawingOnlyNotes() {
        let annotation = Annotation(
            locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)),
            text: "sketched passage",
            chapterTitle: "Chapter 1",
            hasDrawing: true
        )
        let markdown = NoteMarkdown.exportDocument(
            bookTitle: "Book",
            author: "Author",
            annotations: [annotation]
        )
        XCTAssertTrue(markdown.contains("> sketched passage"))
        XCTAssertTrue(markdown.contains("_Visual note attached._"))
        XCTAssertFalse(markdown.contains("_No notes yet._"))
    }

    func testLibraryStoreMigratesV1ToCurrent() throws {
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
        XCTAssertNil(record.sourceURL)

        store.flush()
        let reloaded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(reloaded?["version"] as? Int, LibraryStore.currentVersion)
    }
}
