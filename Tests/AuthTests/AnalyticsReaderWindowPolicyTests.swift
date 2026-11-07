import XCTest

final class AnalyticsReaderWindowPolicyTests: XCTestCase {
    func testReaderOwnedEditingAndTemporaryToolsCountAsOneEngagementContext() {
        for context: AnalyticsReaderWindowPolicy.KeyContext in [.reader, .editor, .transient] {
            XCTAssertTrue(AnalyticsReaderWindowPolicy.isEngaged(readerVisible: true,
                readerMinimized: false, appActive: true, keyContext: context))
        }
    }

    func testUnrelatedWindowsAndSheetsDoNotKeepTheReaderEngaged() {
        for context: AnalyticsReaderWindowPolicy.KeyContext in [.unrelated, .none] {
            XCTAssertFalse(AnalyticsReaderWindowPolicy.isEngaged(readerVisible: true,
                readerMinimized: false, appActive: true, keyContext: context))
        }
    }

    func testHiddenMinimizedAndInactiveReaderCannotAccrueEditorEngagement() {
        for context: AnalyticsReaderWindowPolicy.KeyContext in [.reader, .editor, .transient] {
            XCTAssertFalse(AnalyticsReaderWindowPolicy.isEngaged(readerVisible: false,
                readerMinimized: false, appActive: true, keyContext: context))
            XCTAssertFalse(AnalyticsReaderWindowPolicy.isEngaged(readerVisible: true,
                readerMinimized: true, appActive: true, keyContext: context))
            XCTAssertFalse(AnalyticsReaderWindowPolicy.isEngaged(readerVisible: true,
                readerMinimized: false, appActive: false, keyContext: context))
        }
    }
}
