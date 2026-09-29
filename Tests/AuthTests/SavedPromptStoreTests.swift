import Foundation
import XCTest

@MainActor
final class SavedPromptStoreTests: XCTestCase {
    func testSavedPromptsPersistAcrossStoreInstancesAndCanBeEditedOrDeleted() throws {
        let suite = "SavedPromptStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedPromptStore(defaults: defaults)
        XCTAssertTrue(store.save(title: " ELI5 ", text: " Explain this simply. "))
        XCTAssertEqual(store.prompts.count, 1)
        let id = try XCTUnwrap(store.prompts.first?.id)

        let reopened = SavedPromptStore(defaults: defaults)
        XCTAssertEqual(reopened.prompts.first?.title, "ELI5")
        XCTAssertEqual(reopened.prompts.first?.text, "Explain this simply.")
        XCTAssertFalse(reopened.save(title: "eli5", text: "Duplicate badge"))
        XCTAssertTrue(reopened.save(id: id, title: "Simple", text: "Use plain words."))
        XCTAssertEqual(reopened.prompts.count, 1)

        let edited = SavedPromptStore(defaults: defaults)
        XCTAssertEqual(edited.prompts.first?.title, "Simple")
        edited.delete(id)
        XCTAssertTrue(SavedPromptStore(defaults: defaults).prompts.isEmpty)
    }
}
