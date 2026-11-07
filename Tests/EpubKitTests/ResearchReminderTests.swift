import CloudKit
import XCTest
@testable import EpubKit

final class ResearchReminderTests: XCTestCase {
    private func reminder() -> ResearchReminder {
        ResearchReminder(title: "Research database sharding", source: .note,
            locator: .pdfPage(12, text: "database sharding"), quotedText: "database sharding",
            chapterTitle: "Scaling databases", annotationID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1))
    }

    func testLegacyBookDecodesWithNoReminders() throws {
        let data = Data(#"{"id":"book","title":"Book","author":"Author","lastOpenedAt":0,"progress":0,"annotations":[],"bookmarks":[]}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(BookRecord.self, from: data).reminders.isEmpty)
    }

    func testReminderSurvivesRelaunchCompletionAndSourceDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: file)
        let task = reminder()
        let note = Annotation(id: task.annotationID!, locator: task.locator, text: task.quotedText, note: "A thought")
        store.upsert(BookRecord(id: "book", title: "Book", author: "", annotations: [note], reminders: [task]))
        try store.checkpoint()
        try store.updateAndFlush("book") {
            $0.annotations.removeAll()
            $0.reminders[0].completedAt = Date(timeIntervalSince1970: 2)
        }
        let saved = try XCTUnwrap(LibraryStore(fileURL: file).record(for: "book")?.reminders.first)
        XCTAssertEqual(saved.id, task.id)
        XCTAssertEqual(saved.locator, task.locator)
        XCTAssertEqual(saved.quotedText, task.quotedText)
        XCTAssertEqual(saved.chapterTitle, task.chapterTitle)
        XCTAssertTrue(saved.isCompleted)
        try store.updateAndFlush("book") { $0.reminders[0].completedAt = nil }
        XCTAssertFalse(try XCTUnwrap(LibraryStore(fileURL: file).record(for: "book")?.reminders.first).isCompleted)
    }

    func testFailedDurableUpdateRollsBackNoteAndReminder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: file)
        let note = Annotation(locator: .startOfBook(), text: "quote", note: "Before")
        store.upsert(BookRecord(id: "book", title: "Book", author: "", annotations: [note]))
        try store.checkpoint()
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.updateAndFlush("book") {
            $0.annotations[0].note = "After"
            $0.reminders.append(reminder())
        })
        XCTAssertEqual(store.record(for: "book")?.annotations[0].note, "Before")
        XCTAssertTrue(try XCTUnwrap(store.record(for: "book")).reminders.isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.durableBooks().first).reminders.isEmpty)
        try FileManager.default.removeItem(at: file)
        try store.checkpoint()
        XCTAssertTrue(try XCTUnwrap(LibraryStore(fileURL: file).record(for: "book")).reminders.isEmpty)
    }

    private func entity(_ task: ResearchReminder, device: String = "a", time: TimeInterval = 1) throws -> SyncEntity {
        SyncEntity(bookID: "book", kind: .reminder, key: task.id.uuidString,
            body: try SyncCoding.encode(task), modifiedAt: Date(timeIntervalSince1970: time), deviceID: device)
    }

    func testTitleEditAndCompletionMergeIndependently() throws {
        let task = reminder()
        var local = task, remote = task
        local.title = "Research hash-based sharding"
        local.modifiedAt = Date(timeIntervalSince1970: 2)
        remote.completedAt = Date(timeIntervalSince1970: 2)
        remote.modifiedAt = Date(timeIntervalSince1970: 3)
        let merged = try SyncMerge.resolve(local: entity(local), remote: entity(remote, device: "b", time: 2), ancestor: entity(task))
        XCTAssertEqual(merged.count, 1)
        let result = try merged[0].value(ResearchReminder.self)
        XCTAssertEqual(result.title, local.title)
        XCTAssertEqual(result.completedAt, remote.completedAt)
        XCTAssertEqual(result.modifiedAt, remote.modifiedAt)
    }

    func testConcurrentCompletionUsesDeterministicWinnerWithoutDuplicates() throws {
        let task = reminder()
        var local = task, remote = task
        local.completedAt = Date(timeIntervalSince1970: 2)
        local.modifiedAt = Date(timeIntervalSince1970: 2)
        remote.completedAt = Date(timeIntervalSince1970: 3)
        remote.modifiedAt = Date(timeIntervalSince1970: 3)
        let a = try entity(local, time: 2), b = try entity(remote, device: "b", time: 3)
        let merged = try SyncMerge.resolve(local: a, remote: b, ancestor: entity(task))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(try merged[0].value(ResearchReminder.self).completedAt, remote.completedAt)
        XCTAssertEqual(merged, try SyncMerge.resolve(local: b, remote: a, ancestor: entity(task)))
    }

    func testConflictingTitlesKeepStableRecoveryCopyAndDeletionWins() throws {
        let task = reminder()
        var local = task, remote = task
        local.title = "Research range-based sharding"
        remote.title = "Research directory-based sharding"
        let a = try entity(local), b = try entity(remote, device: "b", time: 2)
        let merged = try SyncMerge.resolve(local: a, remote: b, ancestor: entity(task))
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(try merged[0].value(ResearchReminder.self).title, remote.title)
        XCTAssertEqual(try merged[1].value(ResearchReminder.self).title, "Recovered version: " + local.title)
        XCTAssertEqual(merged, try SyncMerge.resolve(local: b, remote: a, ancestor: entity(task)))
        var deleted = b; deleted.deleted = true; deleted.body = Data()
        XCTAssertEqual(try SyncMerge.resolve(local: a, remote: deleted, ancestor: entity(task)), [deleted])
    }

    @MainActor
    func testReminderCloudZoneIsSeparateFromOlderClientLibraryScope() async {
        XCTAssertEqual(CloudKitSyncTransport.zoneName(for: .reminder), CloudKitSyncTransport.reminderZone)
        XCTAssertNotEqual(CloudKitSyncTransport.reminderZone, CloudKitSyncTransport.libraryZone)
        let reminderZone = CKRecordZone.ID(zoneName: CloudKitSyncTransport.reminderZone)
        XCTAssertTrue(CloudKitSyncTransport.metadataFetchScope(aiEnabled: false).contains(reminderZone))
        let oldLibraryOnly = CKSyncEngine.FetchChangesOptions.Scope.zoneIDs([.init(zoneName: CloudKitSyncTransport.libraryZone)])
        XCTAssertFalse(CloudKitSyncTransport.metadataFetchScope(aiEnabled: false, requested: oldLibraryOnly).contains(reminderZone))
    }
}
