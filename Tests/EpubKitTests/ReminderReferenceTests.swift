import XCTest
@testable import EpubKit

final class ReminderReferenceTests: XCTestCase {
    private let locator = Locator(spineIndex: 0, start: TextPosition(elementPath: [], offset: 0))

    func testReferencesPreserveIdentityEscapingAndUnicodeOffsets() throws {
        let id = UUID()
        let title = "Research [sharding] \\ routing 👩🏽‍💻"
        let link = ReminderReference.markdown(id: id, title: title)
        let note = "Before 👋\n\n" + link + "\n\nAfter"
        let reference = try XCTUnwrap(ReminderReference.references(in: note).first)
        XCTAssertEqual(reference.id, id)
        XCTAssertEqual(reference.title, title)
        XCTAssertEqual((note as NSString).substring(with: reference.range), link)
        XCTAssertEqual(ReminderReference.replacing(in: note) { _ in "replacement" }, "Before 👋\n\nreplacement\n\nAfter")
        XCTAssertEqual(NoteMarkdown.plainPreview(of: link), title)
        XCTAssertTrue(NoteMarkdown.unsupportedConstructs(in: link).isEmpty)
    }

    func testOnlyStandaloneReferencesOutsideCodeAreReminderBlocks() {
        let id = UUID(), other = UUID()
        let link = ReminderReference.markdown(id: id, title: "Research sharding")
        let sketch = NoteSketch(title: "Database layout")
        let audio = NoteAudio(title: "Thought")
        let note = "```\n" + link + "\n```\n\n" + sketch.markdown + "\n\n" + link
            + "\n\n" + audio.markdown + "\n\n~~~text\n" + link + "\n~~~\n\n"
            + ReminderReference.markdown(id: other, title: "Read more")
        XCTAssertEqual(ReminderReference.references(in: note).map(\.id), [id, other])
        let blocks = NoteMarkdown.previewBlocks(of: note).filter {
            switch $0 { case .sketch, .audio, .reminder: return true; default: return false }
        }
        XCTAssertEqual(blocks, [.sketch(sketch.id, sketch.title), .reminder(id, "Research sharding"),
                                .audio(audio.id, audio.title), .reminder(other, "Read more")])
        for prose in ["Look at " + link, "    " + link, "`" + link + "`"] {
            XCTAssertTrue(ReminderReference.references(in: prose).isEmpty)
        }
    }

    func testAliasesAcceptTopicsAndPrefixesButLeaveProseAndCodeAlone() {
        for command in ["/", "/r", "/rem", "/remind", "/t", "/task", "/remind Research sharding", "/task 👋 Read more"] {
            let prefix = "Before 👩🏽‍💻\n\n"
            let note = prefix + command + "\n\nAfter"
            let selection = NSRange(location: (prefix + command).utf16.count, length: 0)
            XCTAssertEqual(ReminderReference.commandSuggestionRange(in: note, selection: selection),
                           NSRange(location: prefix.utf16.count, length: command.utf16.count))
        }
        for text in ["", "Prose /remind", "    /task", "/reminder", "/tasker", "/audio", "`/remind`", "```\n/remind", "~~~\n/task"] {
            XCTAssertNil(ReminderReference.commandSuggestionRange(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
        }
        XCTAssertNil(ReminderReference.commandRange(in: "/rem", selection: NSRange(location: 4, length: 0)))
        XCTAssertNotNil(ReminderReference.commandRange(in: "/task Research sharding", selection: NSRange(location: 23, length: 0)))
        XCTAssertNil(ReminderReference.commandRange(in: "/task", selection: NSRange(location: 0, length: 5)))
        XCTAssertNil(ReminderReference.commandSuggestionRange(in: "/task Research", selection: NSRange(location: 5, length: 0)), "Do not consume an unselected suffix")
        XCTAssertEqual(ReminderReference.commandTitle(in: "/remind Research sharding"), "Research sharding")
        XCTAssertEqual(ReminderReference.commandTitle(in: "/task\tRead more  "), "Read more")
        XCTAssertEqual(ReminderReference.commandTitle(in: "/rem"), "")
    }

    func testExportsUseCanonicalTitleAndCompletionWithoutPromotingNormalChecklists() {
        let reminder = ResearchReminder(title: "Research [sharding] <routing>", source: .note,
            locator: locator, completedAt: Date())
        let link = ReminderReference.markdown(id: reminder.id, title: "Old title")
        let note = "Before\n\n" + link + "\n\n- [ ] Ordinary note checklist\n\n```\n" + link + "\n```"
        let annotation = Annotation(locator: locator, text: "Passage", note: note)
        let exported = NoteMarkdown.exportDocument(bookTitle: "Book", author: "Author",
                                                   annotations: [annotation], reminders: [reminder])
        XCTAssertTrue(exported.contains("- [x] Research \\[sharding\\] \\<routing\\>"))
        XCTAssertTrue(exported.contains("- [ ] Ordinary note checklist"))
        XCTAssertTrue(exported.contains("```\n" + link + "\n```"), "Literal code must remain untouched")
        let html = NoteExport.html(bookTitle: "Book", author: "Author", annotations: [annotation], reminders: [reminder])
        XCTAssertTrue(html.contains("☑"))
        XCTAssertTrue(html.contains("Research [sharding] &lt;routing&gt;"))
        XCTAssertFalse(html.contains(">Old title</a>"))
        XCTAssertEqual(ReminderReference.exporting(link), "- [ ] Old title", "A removed reminder keeps readable fallback text")
        XCTAssertTrue(ReminderReference.references(in: "- [ ] Ordinary note checklist").isEmpty)
    }
}
