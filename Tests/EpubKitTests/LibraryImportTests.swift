import XCTest
@testable import EpubKit

final class LibraryImportTests: XCTestCase {
    func testImportBookCopiesIntoBooksDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodi-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let libraryURL = root.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: libraryURL)

        let source = SampleBooks.url(SampleBooks.frankenstein)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Missing sample. Run Scripts/fetch-samples.sh.")
        }
        let imported = try store.importBook(from: source, bookID: "urn:example:frankenstein")

        XCTAssertTrue(store.isImportedURL(imported))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertEqual(
            imported.lastPathComponent,
            LibraryStore.sanitizedFileName(for: "urn:example:frankenstein") + ".epub"
        )

        // Re-import from the copy is a no-op path-wise.
        let again = try store.importBook(from: imported, bookID: "urn:example:frankenstein")
        XCTAssertEqual(again.path, imported.path)

        var record = BookRecord(id: "urn:example:frankenstein", title: "F", author: "A")
        record.importedRelativePath = LibraryStore.relativeImportedPath(for: record.id)
        XCTAssertEqual(store.existingImportedURL(for: record)?.path, imported.path)
    }

    func testBookRecordDecodesWithoutImportedRelativePath() throws {
        let json = """
        {
          "id": "book-1",
          "title": "Test",
          "author": "Author",
          "lastOpenedAt": 0,
          "progress": 0,
          "annotations": [],
          "bookmarks": []
        }
        """.data(using: .utf8)!
        let record = try JSONDecoder().decode(BookRecord.self, from: json)
        XCTAssertNil(record.importedRelativePath)
        XCTAssertNil(record.chatMessages)
        XCTAssertNil(record.sourceURL)
        XCTAssertFalse(record.isWebDocument)
        XCTAssertEqual(record.conversation, [])
    }

    func testBookRecordRoundTripsSourceURL() throws {
        var record = BookRecord(
            id: "web-1",
            title: "An Article",
            author: "Site",
            sourceURL: URL(string: "https://example.com/post")
        )
        record.annotations = [
            Annotation(
                locator: Locator(
                    spineIndex: 0,
                    start: TextPosition(elementPath: [0], offset: 0)
                ),
                text: "quote"
            ),
        ]
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(BookRecord.self, from: data)
        XCTAssertEqual(decoded.sourceURL?.absoluteString, "https://example.com/post")
        XCTAssertTrue(decoded.isWebDocument)
        XCTAssertEqual(decoded.annotations.count, 1)
    }

    func testLibraryStoreMigratesToV3() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kodi-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let libraryURL = root.appendingPathComponent("library.json")
        let v2 = """
        {"version": 2, "books": {}}
        """.data(using: .utf8)!
        try v2.write(to: libraryURL)

        let store = LibraryStore(fileURL: libraryURL)
        XCTAssertEqual(store.schemaVersion, LibraryStore.currentVersion)
        XCTAssertEqual(LibraryStore.currentVersion, 3)
    }

    func testBookRecordRoundTripsChatMessages() throws {
        var record = BookRecord(id: "book-1", title: "Test", author: "Author")
        record.chatMessages = [
            ChatMessage(role: .user, text: "What does this mean?", references: [
                ChatReference(
                    quotedText: "Call me Ishmael.",
                    chapterTitle: "Chapter 1",
                    spineIndex: 0,
                    contextBefore: "Some years ago—never mind how long precisely—",
                    contextAfter: "having little or no money in my purse,"
                ),
            ]),
            ChatMessage(role: .assistant, text: "It is the narrator introducing himself."),
        ]
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(BookRecord.self, from: data)
        XCTAssertEqual(decoded.conversation.count, 2)
        XCTAssertEqual(decoded.conversation[0].text, "What does this mean?")
        XCTAssertEqual(decoded.conversation[0].references.first?.quotedText, "Call me Ishmael.")
        XCTAssertEqual(
            decoded.conversation[0].references.first?.contextBefore,
            "Some years ago—never mind how long precisely—"
        )
        XCTAssertEqual(
            decoded.conversation[0].references.first?.contextAfter,
            "having little or no money in my purse,"
        )
        XCTAssertEqual(decoded.conversation[1].role, .assistant)
    }

    func testConversationThreadsWrapsLegacyChatMessages() throws {
        var record = BookRecord(id: "book-1", title: "Test", author: "Author")
        record.chatMessages = [
            ChatMessage(role: .user, text: "What is a monolith?"),
            ChatMessage(role: .assistant, text: "One big service."),
        ]
        XCTAssertEqual(record.conversationThreads.count, 1)
        XCTAssertEqual(record.conversationThreads[0].title, "What is a monolith?")
        XCTAssertEqual(record.conversation, record.chatMessages)
    }

    func testChatThreadsRoundTrip() throws {
        let first = ChatThread(
            title: "What is a monolith?",
            messages: [ChatMessage(role: .user, text: "What is a monolith?")]
        )
        let second = ChatThread(
            title: "Explain Spinnaker",
            messages: [ChatMessage(role: .user, text: "Explain Spinnaker")]
        )
        var record = BookRecord(id: "book-1", title: "Test", author: "Author")
        record.chats = [first, second]
        record.activeChatID = second.id
        record.chatMessages = second.messages

        let decoded = try JSONDecoder().decode(BookRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.conversationThreads.count, 2)
        XCTAssertEqual(decoded.activeChatID, second.id)
        XCTAssertEqual(decoded.conversation.first?.text, "Explain Spinnaker")
        XCTAssertEqual(decoded.chats?.map(\.title), ["What is a monolith?", "Explain Spinnaker"])
    }

    func testChatReferenceDecodesWithoutSurroundingContext() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "quotedText": "Call me Ishmael.",
          "chapterTitle": "Chapter 1",
          "spineIndex": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatReference.self, from: json)
        XCTAssertEqual(decoded.quotedText, "Call me Ishmael.")
        XCTAssertNil(decoded.contextBefore)
        XCTAssertNil(decoded.contextAfter)
        XCTAssertFalse(decoded.hasSurroundingContext)
    }
}
