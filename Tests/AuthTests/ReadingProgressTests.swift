import Foundation
import XCTest

@MainActor
final class ReadingProgressTests: XCTestCase {
    private final class Clock {
        var uptime: TimeInterval = 0
        var now: Date
        var calendar: Calendar

        init(now: Date, timeZone: TimeZone) {
            self.now = now
            calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
        }

        func advance(_ seconds: TimeInterval) {
            uptime += seconds
            now = now.addingTimeInterval(seconds)
        }
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func context(at value: String = "2026-10-20T12:00:00Z",
                         timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> (ReadingProgress, Clock, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KodiReadingProgressTests.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(now: date(value), timeZone: timeZone)
        return (makeProgress(directory: directory, clock: clock), clock, directory)
    }

    private func makeProgress(directory: URL, clock: Clock) -> ReadingProgress {
        ReadingProgress(directory: directory, startTimer: false,
                        uptime: { clock.uptime }, date: { clock.now }, calendar: { clock.calendar })
    }

    private func start(_ progress: ReadingProgress) {
        progress.setActive(true)
        progress.setReaderEligible(true)
        progress.setReadingWindowVisible(true)
        progress.recordInteraction()
    }

    private func read(_ seconds: TimeInterval, progress: ReadingProgress, clock: Clock) {
        var remaining = seconds
        while remaining > 0 {
            let interval = min(15, remaining)
            clock.advance(interval)
            progress.tick()
            progress.recordInteraction()
            remaining -= interval
        }
    }

    private func move(to value: String, progress: ReadingProgress, clock: Clock) {
        progress.setActive(false)
        clock.advance(date(value).timeIntervalSince(clock.now))
        progress.tick()
        start(progress)
    }

    func testDefaultGoalAndWholeMinuteBounds() {
        let (progress, _, _) = context()
        XCTAssertEqual(progress.goalMinutes, 5)
        XCTAssertEqual(progress.todaySeconds, 0)
        XCTAssertFalse(progress.isTodayComplete)
        XCTAssertEqual(progress.currentStreak, 0)
        XCTAssertFalse(progress.setGoal(minutes: 0))
        XCTAssertFalse(progress.setGoal(minutes: 4))
        XCTAssertEqual(progress.goalMinutes, 5)
        XCTAssertTrue(progress.setGoal(minutes: 1_440))
        XCTAssertEqual(progress.goalMinutes, 1_440)
        XCTAssertFalse(progress.setGoal(minutes: 1_441))
        XCTAssertEqual(progress.goalMinutes, 1_440)
        XCTAssertTrue(progress.setGoal(minutes: 5))
        XCTAssertEqual(progress.goalMinutes, 5)
        XCTAssertNil(progress.storageError)
    }

    func testOnlyActiveEligibleVisibleReaderAccrues() {
        let (progress, clock, _) = context()
        clock.advance(15)
        progress.tick()
        progress.setActive(true)
        clock.advance(15)
        progress.tick()
        progress.setReaderEligible(true)
        clock.advance(15)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 0)

        progress.setReadingWindowVisible(true)
        progress.recordInteraction()
        clock.advance(15)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 15)
    }

    func testMultipleSessionsAndDocumentsAccumulateTowardOneDailyGoal() {
        let (progress, clock, _) = context()
        start(progress)
        read(120, progress: progress, clock: clock)
        progress.setReaderEligible(false)
        clock.advance(60)
        progress.tick()
        progress.setReaderEligible(true)
        progress.recordInteraction()
        read(179, progress: progress, clock: clock)
        XCTAssertEqual(progress.todaySeconds, 299)
        XCTAssertFalse(progress.isTodayComplete)
        read(1, progress: progress, clock: clock)
        XCTAssertEqual(progress.todaySeconds, 300)
        XCTAssertTrue(progress.isTodayComplete)
        XCTAssertEqual(progress.currentStreak, 1)
        read(60, progress: progress, clock: clock)
        XCTAssertEqual(progress.todaySeconds, 360)
        XCTAssertEqual(progress.currentStreak, 1, "Extra reading cannot earn another day")
    }

    func testFiveQuietMinutesCountBeforeIdleCutoff() {
        let (progress, clock, _) = context()
        start(progress)
        clock.advance(300)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 300)
        XCTAssertTrue(progress.isTodayComplete)
        clock.advance(300)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 300)
    }

    func testInputAfterIdleResumesWithoutBackfillingGap() {
        let (progress, clock, _) = context()
        start(progress)
        clock.advance(900)
        progress.recordInteraction()
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 300)
        clock.advance(20)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 320)
    }

    func testFractionalSecondsSurviveFrequentTicks() {
        let (progress, clock, _) = context()
        start(progress)
        for _ in 0..<10 {
            clock.advance(0.25)
            progress.tick()
        }
        XCTAssertEqual(progress.todaySeconds, 2.5, accuracy: 0.000_001)
    }

    func testBackgroundVisibilityAndSleepPauseImmediately() {
        let (progress, clock, _) = context()
        start(progress)
        clock.advance(10)
        progress.setActive(false)
        clock.advance(600)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 10)

        progress.setActive(true)
        progress.recordInteraction()
        clock.advance(10)
        progress.setReadingWindowVisible(false)
        clock.advance(600)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 20)

        progress.setReadingWindowVisible(true)
        progress.recordInteraction()
        clock.advance(10)
        progress.setSleeping(true)
        clock.advance(600)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 30)

        progress.setSleeping(false)
        progress.recordInteraction()
        clock.advance(10)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 40)
    }

    func testDuplicateLifecycleAndTickEventsDoNotDoubleCount() {
        let (progress, clock, _) = context()
        start(progress)
        clock.advance(60)
        progress.setActive(true)
        progress.setActive(true)
        progress.setReaderEligible(true)
        progress.setReadingWindowVisible(true)
        progress.tick()
        progress.tick()
        progress.checkpoint()
        XCTAssertEqual(progress.todaySeconds, 60)
        clock.advance(15)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 75)
    }

    func testLoweredGoalUsesExistingReadingAndRaisedGoalNeverRevokesEarnedDay() {
        let (progress, clock, _) = context()
        XCTAssertTrue(progress.setGoal(minutes: 10))
        start(progress)
        read(300, progress: progress, clock: clock)
        XCTAssertFalse(progress.isTodayComplete)
        XCTAssertTrue(progress.setGoal(minutes: 5))
        XCTAssertTrue(progress.isTodayComplete)
        XCTAssertEqual(progress.currentStreak, 1)
        XCTAssertTrue(progress.setGoal(minutes: 10))
        XCTAssertTrue(progress.isTodayComplete)
        XCTAssertEqual(progress.currentStreak, 1)

        move(to: "2026-10-21T12:00:00Z", progress: progress, clock: clock)
        XCTAssertEqual(progress.goalMinutes, 10)
        XCTAssertEqual(progress.todaySeconds, 0)
        XCTAssertFalse(progress.isTodayComplete)
        read(300, progress: progress, clock: clock)
        XCTAssertFalse(progress.isTodayComplete)
        read(300, progress: progress, clock: clock)
        XCTAssertTrue(progress.isTodayComplete)
        XCTAssertEqual(progress.currentStreak, 2)
    }

    func testRelaunchRestoresPartialTimeGoalAndCompletedStatus() {
        let (progress, clock, directory) = context()
        XCTAssertTrue(progress.setGoal(minutes: 8))
        start(progress)
        read(125.5, progress: progress, clock: clock)
        progress.checkpoint()
        let restored = makeProgress(directory: directory, clock: clock)
        XCTAssertEqual(restored.goalMinutes, 8)
        XCTAssertEqual(restored.todaySeconds, 125.5, accuracy: 0.000_001)
        XCTAssertFalse(restored.isTodayComplete)

        start(restored)
        read(354.5, progress: restored, clock: clock)
        XCTAssertTrue(restored.isTodayComplete)
        XCTAssertTrue(restored.setGoal(minutes: 20))
        restored.checkpoint()
        let completed = makeProgress(directory: directory, clock: clock)
        XCTAssertEqual(completed.goalMinutes, 20)
        XCTAssertEqual(completed.todaySeconds, 480, accuracy: 0.000_001)
        XCTAssertTrue(completed.isTodayComplete)
        XCTAssertEqual(completed.currentStreak, 1)
        XCTAssertNil(completed.storageError)

        clock.advance(60)
        completed.tick()
        XCTAssertEqual(completed.todaySeconds, 480, "A relaunched service starts paused")
    }

    func testCheckpointIncludesTimeSinceLastTimerTick() {
        let (progress, clock, directory) = context()
        start(progress)
        clock.advance(42)
        progress.checkpoint()
        let restored = makeProgress(directory: directory, clock: clock)
        XCTAssertEqual(restored.todaySeconds, 42)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("reading-progress.json").path))
    }

    func testIdleCutoffPersistsFinalPartialSaveInterval() {
        let (progress, clock, directory) = context()
        XCTAssertTrue(progress.setGoal(minutes: 10))
        start(progress)
        clock.advance(295.5)
        progress.checkpoint()
        clock.advance(4.5)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 300)
        XCTAssertFalse(progress.isTodayComplete, "Persistence must not depend on earning a day")

        let restored = makeProgress(directory: directory, clock: clock)
        XCTAssertEqual(restored.todaySeconds, 300)
        XCTAssertEqual(restored.goalMinutes, 10)
        XCTAssertFalse(restored.isTodayComplete)
    }

    func testYesterdayKeepsStreakUntilAnEntireDayIsMissed() {
        let (progress, clock, _) = context()
        start(progress)
        read(300, progress: progress, clock: clock)
        move(to: "2026-10-21T12:00:00Z", progress: progress, clock: clock)
        XCTAssertEqual(progress.currentStreak, 1)
        XCTAssertFalse(progress.isTodayComplete)
        read(300, progress: progress, clock: clock)
        XCTAssertEqual(progress.currentStreak, 2)
        move(to: "2026-10-22T12:00:00Z", progress: progress, clock: clock)
        XCTAssertEqual(progress.currentStreak, 2)
        move(to: "2026-10-23T12:00:00Z", progress: progress, clock: clock)
        XCTAssertEqual(progress.currentStreak, 0)
        read(300, progress: progress, clock: clock)
        XCTAssertEqual(progress.currentStreak, 1)
    }

    func testReadingAcrossMidnightSplitsTimeBetweenCalendarDays() {
        let (progress, clock, directory) = context(at: "2026-10-20T23:55:00Z")
        start(progress)
        read(360, progress: progress, clock: clock)
        XCTAssertEqual(progress.todaySeconds, 60)
        XCTAssertFalse(progress.isTodayComplete)
        XCTAssertEqual(progress.currentStreak, 1, "The five minutes before midnight complete yesterday")
        progress.checkpoint()
        let restored = makeProgress(directory: directory, clock: clock)
        XCTAssertEqual(restored.todaySeconds, 60)
        XCTAssertEqual(restored.currentStreak, 1)
    }

    func testDayRollsOverWhilePausedWithoutAddingTime() {
        let (progress, clock, _) = context(at: "2026-10-20T23:58:00Z")
        start(progress)
        read(60, progress: progress, clock: clock)
        progress.setReadingWindowVisible(false)
        clock.advance(120)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 0)
        XCTAssertFalse(progress.isTodayComplete)
        XCTAssertEqual(progress.currentStreak, 0)
    }

    func testDSTClockChangeDoesNotInflateReadingDuration() {
        let (progress, clock, _) = context(at: "2026-03-08T01:59:00-08:00",
                                           timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        start(progress)
        read(120, progress: progress, clock: clock)
        XCTAssertEqual(clock.calendar.component(.hour, from: clock.now), 3)
        XCTAssertEqual(progress.todaySeconds, 120)
        XCTAssertFalse(progress.isTodayComplete)
    }

    func testConsecutiveLocalDaysIncludeTwentyThreeHourDSTDay() {
        let (progress, clock, _) = context(at: "2026-03-07T12:00:00-08:00",
                                           timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        start(progress)
        read(300, progress: progress, clock: clock)
        move(to: "2026-03-08T12:00:00-07:00", progress: progress, clock: clock)
        read(300, progress: progress, clock: clock)
        move(to: "2026-03-09T12:00:00-07:00", progress: progress, clock: clock)
        read(300, progress: progress, clock: clock)
        XCTAssertEqual(progress.currentStreak, 3)
    }

    func testForwardAndBackwardWallClockChangesCannotInflateTime() {
        let (progress, clock, _) = context()
        start(progress)
        clock.uptime += 30
        clock.now = clock.now.addingTimeInterval(3_600)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 30)
        clock.uptime += 30
        clock.now = clock.now.addingTimeInterval(-1_800)
        progress.tick()
        XCTAssertEqual(progress.todaySeconds, 60)
        XCTAssertFalse(progress.isTodayComplete)
    }

    func testLocalReadingWorksWhenAnalyticsCollectionIsUnavailable() {
        let (progress, clock, directory) = context()
        start(progress)
        clock.advance(300)
        progress.tick()
        progress.checkpoint()
        XCTAssertTrue(progress.isTodayComplete)
        XCTAssertEqual(progress.currentStreak, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Analytics").path))
    }

    func testStorageFailureDoesNotLoseInMemoryProgressOrInterruptReading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KodiReadingProgressBlocked.\(UUID().uuidString)")
        try Data("occupied".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(now: date("2026-10-20T12:00:00Z"), timeZone: TimeZone(secondsFromGMT: 0)!)
        let progress = makeProgress(directory: directory, clock: clock)
        start(progress)
        read(300, progress: progress, clock: clock)
        progress.checkpoint()
        XCTAssertEqual(progress.todaySeconds, 300)
        XCTAssertTrue(progress.isTodayComplete)
        XCTAssertNotNil(progress.storageError)
    }

    func testMalformedHistoryIsPreservedAfterNewReadingAndCheckpoint() throws {
        let (_, clock, directory) = context()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("reading-progress.json")
        let original = Data("{saved history is incomplete".utf8)
        try original.write(to: file)

        let progress = makeProgress(directory: directory, clock: clock)
        XCTAssertNotNil(progress.storageError)
        start(progress)
        read(60, progress: progress, clock: clock)
        progress.checkpoint()
        XCTAssertEqual(progress.todaySeconds, 60)
        XCTAssertNotNil(progress.storageError)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFutureHistoryVersionIsPreservedAfterGoalChangeAndCheckpoint() throws {
        let (_, clock, directory) = context()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("reading-progress.json")
        let original = Data(#"{"version":2,"goalMinutes":10,"days":{}}"#.utf8)
        try original.write(to: file)

        let progress = makeProgress(directory: directory, clock: clock)
        XCTAssertNotNil(progress.storageError)
        XCTAssertTrue(progress.setGoal(minutes: 15))
        start(progress)
        read(60, progress: progress, clock: clock)
        progress.checkpoint()
        XCTAssertNotNil(progress.storageError)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testUnreadableHistoryPathIsPreservedAfterCheckpoint() throws {
        let (_, clock, directory) = context()
        let file = directory.appendingPathComponent("reading-progress.json", isDirectory: true)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let marker = file.appendingPathComponent("preserved-history")
        let original = Data("keep this unreadable history intact".utf8)
        try original.write(to: marker)

        let progress = makeProgress(directory: directory, clock: clock)
        XCTAssertNotNil(progress.storageError)
        start(progress)
        read(60, progress: progress, clock: clock)
        progress.checkpoint()
        XCTAssertNotNil(progress.storageError)
        XCTAssertEqual(try Data(contentsOf: marker), original)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
