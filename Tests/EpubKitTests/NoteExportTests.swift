import XCTest
@testable import EpubKit

final class NoteExportTests: XCTestCase {
    private func note(_ text: String = "A <literal> **passage**\nAnother line", body: String = "My **bold** and *italic* note") -> Annotation {
        Annotation(locator: Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0)), text: text, note: body, chapterTitle: "Chapter & One")
    }

    func testHTMLIncludesLiteralPassageCitationAndFormattedNote() {
        let html = NoteExport.html(bookTitle: "Book <Title>", author: "A & B", annotations: [note()])
        XCTAssertTrue(html.contains("A &lt;literal&gt; **passage**<br>Another line"))
        XCTAssertTrue(html.contains("— Chapter &amp; One, A &amp; B, Book &lt;Title&gt;"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
    }

    func testHTMLRendersSourceModeFormattingAndRejectsActiveContent() {
        let body = """
        # Heading

        - bullet

        - [x] done

        | A | B |
        | --- | --- |
        | 1 | 2 |

        ```
        <script>alert('x')</script>
        ```

        <u>**underlined**</u> and [safe](https://example.com?a=1&b=2) and [bad](javascript:alert)
        """
        let html = NoteExport.html(bookTitle: "Book", author: "Author", annotations: [note(body: body)])
        XCTAssertTrue(html.contains("<h1>Heading</h1>"))
        XCTAssertTrue(html.contains("<ul><li>bullet</li></ul>"))
        XCTAssertTrue(html.contains("☑ done"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("<u><strong>underlined</strong></u>"))
        XCTAssertTrue(html.contains("href=\"https://example.com?a=1&amp;b=2\""))
        XCTAssertFalse(html.contains("href=\"javascript:"))
    }

    func testHTMLFiltersBareHighlightsAndKeepsOrphanedQuotes() {
        var orphan = note("Stored quote", body: "Kept note")
        orphan.anchorStatus = .orphaned
        let bare = Annotation(locator: orphan.locator, text: "Bare highlight")
        let html = NoteExport.html(bookTitle: "Book", author: "", annotations: [bare, orphan])
        XCTAssertTrue(html.contains("Stored quote"))
        XCTAssertTrue(html.contains("Kept note"))
        XCTAssertTrue(html.contains("Unknown Author"))
        XCTAssertFalse(html.contains("Bare highlight"))
    }

    func testEmptyAndDrawingOnlyExports() {
        XCTAssertTrue(NoteExport.html(bookTitle: "Book", author: "Author", annotations: []).contains("No notes yet."))
        var drawing = note("Drawing passage", body: "")
        drawing.hasDrawing = true
        let html = NoteExport.html(bookTitle: "Book", author: "Author", annotations: [drawing])
        XCTAssertTrue(html.contains("Drawing passage"))
        XCTAssertTrue(html.contains("drawing is not included"))
    }

    func testMarkdownKeepsPassageLiteralAndNoteFormatting() {
        let markdown = NoteMarkdown.exportDocument(bookTitle: "Book", author: "Author", annotations: [note("A **literal** <passage>")])
        XCTAssertTrue(markdown.contains(#"> A \*\*literal\*\* \<passage\>"#))
        XCTAssertTrue(markdown.contains("My **bold** and *italic* note"))
    }

    func testFormatExtensions() {
        XCTAssertEqual(NoteExportFormat.allCases.map(\.fileExtension), ["md", "docx", "html", "md"])
    }

    func testHTMLAudioHasPortablePlayerAndFileLinkInNoteOrder() {
        let recording = NoteAudio(title: "Thought <one>", duration: 12)
        let annotation = note(body: "Before\n\n" + recording.markdown + "\n\nAfter")
        let path = "Book%20assets/" + recording.id.uuidString + ".m4a"
        let html = NoteExport.html(bookTitle: "Book", author: "Author", annotations: [annotation], audioPaths: [recording.id: path])
        XCTAssertTrue(html.contains("<audio controls preload=\"none\""))
        XCTAssertTrue(html.contains("src=\"\(path)\""))
        XCTAssertTrue(html.contains("href=\"\(path)\">Thought &lt;one&gt;</a>"))
        XCTAssertFalse(html.contains("kodi-audio://"))
        XCTAssertLessThan(html.range(of: "Before")!.lowerBound, html.range(of: "<audio")!.lowerBound)
        XCTAssertLessThan(html.range(of: "<audio")!.lowerBound, html.range(of: "After")!.lowerBound)
        let linkOnly = NoteExport.html(bookTitle: "Book", author: "Author", annotations: [annotation], audioPaths: [recording.id: path], audioPlayers: false)
        XCTAssertFalse(linkOnly.contains("<audio"))
        XCTAssertTrue(linkOnly.contains("href=\"\(path)\""))
    }

    func testHTMLAudioRejectsActivePathsAndShowsMissingRecording() {
        let recording = NoteAudio(title: "Thought", duration: 2)
        let annotation = note(body: recording.markdown)
        for path in ["javascript:alert(1)", "../outside.m4a", "/absolute.m4a", "//example.com/audio.m4a"] {
            let html = NoteExport.html(bookTitle: "Book", author: "Author", annotations: [annotation], audioPaths: [recording.id: path])
            XCTAssertFalse(html.contains("<audio"))
            XCTAssertTrue(html.contains("audio recording unavailable"))
        }
    }

    func testHTMLSavedTranscriptsAreLiteralAndScopedToEachNote() {
        let sharedID = UUID()
        let first = NoteAudio(id: sharedID, title: "First thought", duration: 3,
            transcript: "First <script>alert(1)</script> & **literal**\nSecond line")
        let second = NoteAudio(id: sharedID, title: "Copied thought", duration: 3,
            transcript: "Independent copied transcript")
        var firstNote = note(body: "Before\n\n" + first.markdown + "\n\n" + first.markdown + "\n\nAfter")
        firstNote.audioRecordings = [first]
        var secondNote = note(body: second.markdown)
        secondNote.audioRecordings = [second]
        let html = NoteExport.html(bookTitle: "Book", author: "Author", annotations: [firstNote, secondNote],
                                   audioPaths: [sharedID: "assets/recording.m4a"])
        XCTAssertEqual(html.components(separatedBy: "class=\"audio-transcript\"").count - 1, 2)
        XCTAssertEqual(html.components(separatedBy: "First &lt;script&gt;").count - 1, 1)
        XCTAssertTrue(html.contains("&amp; **literal**<br>Second line"))
        XCTAssertTrue(html.contains("Independent copied transcript"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertLessThan(html.range(of: "First &lt;script&gt;")!.lowerBound, html.range(of: "After")!.lowerBound)
    }

    func testHTMLBlankTranscriptsAreOmittedAndUnavailableAudioKeepsSavedText() {
        var audio = NoteAudio(title: "Thought", duration: 1, transcript: " \n ")
        var annotation = note(body: audio.markdown)
        annotation.audioRecordings = [audio]
        let blank = NoteExport.html(bookTitle: "Book", author: "Author", annotations: [annotation], audioPaths: [audio.id: "assets/a.m4a"])
        XCTAssertFalse(blank.contains("audio-transcript"))
        audio.transcript = "Saved text remains available"
        annotation.audioRecordings = [audio]
        let unavailable = NoteExport.html(bookTitle: "Book", author: "Author", annotations: [annotation])
        XCTAssertTrue(unavailable.contains("audio recording unavailable"))
        XCTAssertTrue(unavailable.contains("Saved text remains available"))
    }
}
