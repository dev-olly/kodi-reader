import Foundation
import XCTest

@MainActor
final class UsageAnalyticsTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(id: UUID = UUID(), at date: Date? = nil) -> AnalyticsEvent {
        AnalyticsEvent(id: id, installationID: UUID(), sessionID: UUID(), occurredAt: date ?? fixedDate,
            name: .readingHeartbeat, durationSeconds: 15,
            properties: .init(platform: "macOS", version: "0.4.7", build: "13", contentType: .epub, errorCategory: nil))
    }

    private func context() -> (UserDefaults, URL) {
        let suite = "KodiAnalyticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, FileManager.default.temporaryDirectory.appendingPathComponent(suite))
    }

    func testWireSchemaContainsOnlyApprovedProperties() throws {
        let item = event()
        let data = try AnalyticsEvent.encoder().encode(item)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["id", "installation_id", "session_id", "occurred_at", "name", "duration_seconds", "properties"]))
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(["platform", "version", "build", "content_type", "schema_version"]))
        XCTAssertEqual(body["name"] as? String, "reading_heartbeat")
        XCTAssertEqual(properties["platform"] as? String, "macOS")
        XCTAssertEqual(properties["schema_version"] as? Int, 3)
        XCTAssertEqual(try AnalyticsEvent.decoder().decode(AnalyticsEvent.self, from: data), item)
    }

    func testLegacyQueueDecodesWithoutInventingAIRequestOrSchemaVersion() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: AnalyticsEvent.encoder().encode(event())) as? [String: Any])
        var properties = try XCTUnwrap(json["properties"] as? [String: Any])
        properties.removeValue(forKey: "schema_version")
        json["properties"] = properties
        let decoded = try AnalyticsEvent.decoder().decode(AnalyticsEvent.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.properties.schemaVersion, 1)
        XCTAssertNil(decoded.properties.requestID)
        XCTAssertEqual(decoded.id.uuidString, json["id"] as? String)
    }

    func testFeatureClockExcludesPausesKeepsShortSegmentsAndBoundsDelayedTicks() {
        var clock = AnalyticsFeatureClock(now: 0)
        XCTAssertEqual(clock.advance(to: 10), 0)
        clock.setActive(true, now: 10)
        XCTAssertEqual(clock.advance(to: 10.6), 0)
        clock.setActive(false, now: 10.6)
        XCTAssertEqual(clock.advance(to: 50), 0)
        clock.setActive(true, now: 50)
        XCTAssertEqual(clock.advance(to: 50.6), 1)
        XCTAssertEqual(clock.advance(to: 1000), 60, "A delayed tick cannot backfill an unbounded sleep")
        clock.reset(now: 2000)
        XCTAssertEqual(clock.advance(to: 2001), 1)
        XCTAssertEqual(clock.advance(to: 1999), 0, "Monotonic-clock reversal never creates negative duration")
    }

    func testRecordingAndListeningClocksFollowActualActivityAndContinueInBackground() async {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        var uptime: TimeInterval = 0
        let analytics = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, uptime: { uptime }, date: { self.fixedDate })
        analytics.setActive(true)
        analytics.setFeatureActivity(.audioRecording, active: true)
        uptime = 15; analytics.tick()
        analytics.setActive(false)
        uptime = 30; analytics.tick()
        uptime = 35; analytics.setFeatureActivity(.audioRecording, active: false)
        uptime = 100; analytics.tick()
        analytics.setFeatureActivity(.ttsListening, active: true)
        uptime = 105; analytics.tick()
        uptime = 112; analytics.setFeatureActivity(.ttsListening, active: false)
        uptime = 200; analytics.tick()
        analytics.record(.audioRecordingHeartbeat)
        analytics.record(.ttsListeningHeartbeat)
        let recording = analytics.pendingEvents.filter { $0.name == .audioRecordingHeartbeat }
        let listening = analytics.pendingEvents.filter { $0.name == .ttsListeningHeartbeat }
        XCTAssertEqual(recording.compactMap(\.durationSeconds).reduce(0, +), 35)
        XCTAssertEqual(listening.compactMap(\.durationSeconds).reduce(0, +), 12)
        XCTAssertTrue((recording + listening).allSatisfy { (1...60).contains($0.durationSeconds ?? 0) && $0.properties.schemaVersion == 3 && $0.properties.contentType == nil && $0.properties.requestID == nil })
        XCTAssertTrue(analytics.pendingEvents.filter { $0.name == .readingHeartbeat }.isEmpty)
        await analytics.persistPendingEvents()
    }

    func testFeatureTimingCannotBackfillAcrossConsentChangesOrCollectInDebug() async {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        var uptime: TimeInterval = 0
        let analytics = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, uptime: { uptime }, date: { self.fixedDate })
        analytics.setFeatureActivity(.ttsListening, active: true)
        uptime = 10; analytics.tick()
        let previousInstallation = analytics.pendingEvents.first?.installationID
        analytics.setEnabled(false)
        uptime = 100; analytics.tick()
        analytics.record(.reminderCreated)
        XCTAssertTrue(analytics.pendingEvents.isEmpty)
        analytics.setEnabled(true)
        uptime = 105; analytics.tick()
        uptime = 106; analytics.setFeatureActivity(.ttsListening, active: false)
        XCTAssertEqual(analytics.pendingEvents.compactMap(\.durationSeconds).reduce(0, +), 6)
        XCTAssertTrue(analytics.pendingEvents.allSatisfy { $0.installationID != previousInstallation })
        await analytics.persistPendingEvents()

        let debugDirectory = directory.appendingPathComponent("debug")
        let debug = UsageAnalytics(defaults: defaults, directory: debugDirectory, collectionAllowed: false,
            networkAllowed: false, startTimer: false, uptime: { uptime }, date: { self.fixedDate })
        debug.setFeatureActivity(.audioRecording, active: true)
        uptime = 120; debug.tick()
        debug.record(.audioRecordingSaved)
        await debug.persistPendingEvents()
        XCTAssertTrue(debug.pendingEvents.isEmpty)
    }

    func testTelemetryOnlyAIRequestIDRoundTripsThroughClosedWireSchema() throws {
        let requestID = UUID()
        let item = AnalyticsEvent(id: UUID(), installationID: UUID(), sessionID: UUID(), occurredAt: fixedDate,
            name: .aiRequestCancelled, durationSeconds: nil,
            properties: .init(platform: "macOS", version: "0.4.7", build: "13", contentType: .pdf,
                              errorCategory: nil, requestID: requestID))
        let data = try AnalyticsEvent.encoder().encode(item)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["platform", "version", "build", "content_type", "schema_version", "request_id"])
        XCTAssertEqual(properties["request_id"] as? String, requestID.uuidString)
        XCTAssertEqual(try AnalyticsEvent.decoder().decode(AnalyticsEvent.self, from: data), item)
    }

    func testEditorCreationAndEditingAreNotAutosaveCounts() {
        var tracker = AnalyticsEditTracker()
        let created = tracker.begin(kind: .note, itemKey: "local-note", isNew: true, content: .epub, now: 0)
        XCTAssertNil(tracker.didPersist(created, meaningful: false), "Empty drafts and failed/unchanged saves do not count")
        XCTAssertEqual(tracker.didPersist(created, meaningful: true)?.name, .noteCreated)
        for second in 1...100 {
            tracker.interacted(at: Double(second))
            XCTAssertEqual(tracker.begin(kind: .note, itemKey: "local-note", isNew: false, content: .epub, now: Double(second)), created)
            XCTAssertNil(tracker.didPersist(created, meaningful: true))
        }
        tracker.end(created)
        let edited = tracker.begin(kind: .note, itemKey: "local-note", isNew: false, content: .epub, now: 101)
        XCTAssertNotEqual(edited, created)
        XCTAssertEqual(tracker.didPersist(edited, meaningful: true)?.name, .noteEditSession)
        XCTAssertNil(tracker.didPersist(edited, meaningful: true))
        let sketch = tracker.begin(kind: .sketch, itemKey: "local-sketch", isNew: true, content: .pdf, now: 102)
        XCTAssertEqual(tracker.didPersist(sketch, meaningful: true)?.name, .sketchCreated)
        tracker.end(sketch)
        let sketchEdit = tracker.begin(kind: .sketch, itemKey: "local-sketch", isNew: false, content: .pdf, now: 103)
        XCTAssertEqual(tracker.didPersist(sketchEdit, meaningful: true)?.name, .sketchEditSession)
    }

    func testEditorIdleBoundariesAndAsynchronousSaveUseOriginalCheckpoint() {
        var tracker = AnalyticsEditTracker()
        let first = tracker.begin(kind: .note, itemKey: "one", isNew: false, content: .epub, now: 0)
        tracker.interacted(at: 50)
        XCTAssertEqual(tracker.begin(kind: .note, itemKey: "one", isNew: false, content: .epub, now: 100), first)
        tracker.expireIdle(at: 170)
        let resumed = tracker.begin(kind: .note, itemKey: "one", isNew: false, content: .epub, now: 171)
        XCTAssertNotEqual(resumed, first)
        tracker.end(resumed)
        let other = tracker.begin(kind: .note, itemKey: "two", isNew: true, content: .pdf, now: 172)
        XCTAssertEqual(tracker.didPersist(first, meaningful: true), .init(name: .noteEditSession, content: .epub))
        XCTAssertEqual(tracker.didPersist(resumed, meaningful: true), .init(name: .noteEditSession, content: .epub))
        tracker.reset()
        XCTAssertNil(tracker.didPersist(other, meaningful: true), "Consent generation changes invalidate delayed saves")
        XCTAssertNil(tracker.didPersist(first, meaningful: true))
    }

    func testConcurrentInitialSaveCheckpointsProduceOneCreation() {
        var tracker = AnalyticsEditTracker()
        let first = tracker.begin(kind: .note, itemKey: "pending-note", isNew: true, content: .epub, now: 0)
        tracker.end(first)
        let resumed = tracker.begin(kind: .note, itemKey: "pending-note", isNew: true, content: .epub, now: 1)
        XCTAssertEqual(tracker.didPersist(resumed, meaningful: true)?.name, .noteCreated)
        XCTAssertNil(tracker.didPersist(first, meaningful: true))
        tracker.end(resumed)
        let laterEdit = tracker.begin(kind: .note, itemKey: "pending-note", isNew: false, content: .epub, now: 2)
        XCTAssertEqual(tracker.didPersist(laterEdit, meaningful: true)?.name, .noteEditSession)
    }

    func testSuccessfulEditsAfterOptOutCannotAttachToReenabledIdentity() async {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        var uptime: TimeInterval = 0
        let analytics = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, uptime: { uptime }, date: { self.fixedDate })
        analytics.setActive(true)
        let token = analytics.beginEditing(kind: .note, itemKey: "private-book:private-note", isNew: true, content: .epub)
        analytics.setEnabled(false)
        analytics.setEnabled(true)
        analytics.noteSuccessfulEdit(token: token, meaningful: true)
        XCTAssertFalse(analytics.pendingEvents.contains { $0.name == .noteCreated })
        let current = analytics.beginEditing(kind: .note, itemKey: "private-book:private-note", isNew: false, content: .epub)
        analytics.noteSuccessfulEdit(token: current, meaningful: true)
        XCTAssertEqual(analytics.pendingEvents.filter { $0.name == .noteEditSession }.count, 1)
        let encoded = try? AnalyticsEvent.encoder().encode(analytics.pendingEvents)
        XCTAssertFalse(String(data: encoded ?? Data(), encoding: .utf8)?.contains("private-book") ?? true)
        analytics.setActive(false)
        uptime = 10; analytics.setActive(true)
        let resumed = analytics.beginEditing(kind: .note, itemKey: "private-book:private-note", isNew: false, content: .epub)
        XCTAssertNotEqual(resumed, current)
        await analytics.persistPendingEvents()
    }

    func testAIRequestCannotBridgeOptOutIdentityResetOrEmitDuplicateOutcomes() async {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let analytics = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, date: { self.fixedDate })
        let oldRequest = UUID()
        analytics.record(.aiRequestStarted, requestID: oldRequest)
        analytics.setEnabled(false)
        analytics.setEnabled(true)
        analytics.record(.aiRequestCompleted, requestID: oldRequest)
        XCTAssertTrue(analytics.pendingEvents.isEmpty)
        let currentRequest = UUID()
        analytics.record(.aiRequestStarted, requestID: currentRequest)
        analytics.record(.aiRequestStarted, requestID: currentRequest)
        analytics.record(.aiRequestCancelled, requestID: currentRequest)
        analytics.record(.aiRequestFailed, requestID: currentRequest)
        XCTAssertEqual(analytics.pendingEvents.map(\.name), [.aiRequestStarted, .aiRequestCancelled])
        XCTAssertTrue(analytics.pendingEvents.allSatisfy { $0.properties.requestID == currentRequest })
        await analytics.persistPendingEvents()
    }

    func testOutboxBoundsDeduplicationRetentionAndStableRetryIDs() {
        let items = (0..<600).map { _ in event() }
        var outbox = AnalyticsOutbox(events: items + [items.last!], now: fixedDate)
        XCTAssertEqual(outbox.events.count, 500)
        XCTAssertEqual(outbox.events.first?.id, items[100].id)
        outbox.append(items.last!, now: fixedDate)
        XCTAssertEqual(outbox.events.count, 500)
        let accepted = Set(outbox.events.prefix(50).map(\.id))
        let remainingIDs = Array(outbox.events.dropFirst(50).map(\.id))
        outbox.acknowledge(accepted)
        XCTAssertEqual(outbox.events.map(\.id), remainingIDs)
        let stale = event(at: fixedDate.addingTimeInterval(-AnalyticsOutbox.retention - 1))
        let future = event(at: fixedDate.addingTimeInterval(301))
        XCTAssertTrue(AnalyticsOutbox(events: [stale, future], now: fixedDate).events.isEmpty)
    }

    func testReadingClockCountsOnlyForegroundContentAndStopsAtIdleBoundary() {
        var clock = AnalyticsReadingClock(now: 0)
        XCTAssertEqual(clock.advance(to: 10), 0)
        clock.setActive(true, now: 10)
        XCTAssertEqual(clock.advance(to: 20), 0)
        clock.setContent(.epub, now: 20)
        XCTAssertEqual(clock.advance(to: 50), 30)
        XCTAssertEqual(clock.advance(to: 110), 60)
        XCTAssertEqual(clock.advance(to: 140), 20) // Input at activation: idle deadline is 130.
        XCTAssertEqual(clock.advance(to: 200), 0)
        clock.interacted(at: 200)
        XCTAssertEqual(clock.advance(to: 215), 15)
        clock.setActive(false, now: 215)
        XCTAssertEqual(clock.advance(to: 400), 0)
    }

    func testDelayedTimerCannotReportMoreThanSixtySeconds() {
        var clock = AnalyticsReadingClock(now: 0)
        clock.setActive(true, now: 0)
        clock.setContent(.pdf, now: 0)
        XCTAssertEqual(clock.advance(to: 3_600), 60)
        XCTAssertEqual(clock.advance(to: 3_620), 0)
        XCTAssertEqual(clock.advance(to: 2), 0)
    }

    func testOptOutClearsDiskAndIdentityAndReenableUsesNewIdentity() async throws {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let analytics = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, date: { self.fixedDate })
        analytics.setActive(true)
        analytics.record(.aiRequestStarted, content: .epub)
        let oldID = try XCTUnwrap(analytics.pendingEvents.first?.installationID)
        await analytics.persistPendingEvents()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("events.json").path))
        analytics.setEnabled(false)
        analytics.record(.pageTurned, content: .epub)
        await analytics.persistPendingEvents()
        XCTAssertTrue(analytics.pendingEvents.isEmpty)
        XCTAssertNil(defaults.string(forKey: UsageAnalytics.installationKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        analytics.setEnabled(true)
        let newID = try XCTUnwrap(analytics.pendingEvents.first?.installationID)
        XCTAssertNotEqual(newID, oldID)
        await analytics.persistPendingEvents()
    }

    func testQueueRestoresPersistedIDsAndConsentAcrossLaunches() async throws {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, date: { self.fixedDate })
        first.setActive(true)
        first.record(.bookImported, content: .pdf)
        await first.persistPendingEvents()
        let second = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, date: { self.fixedDate })
        XCTAssertEqual(first.pendingEvents, second.pendingEvents)
        second.setEnabled(false)
        await second.persistPendingEvents()
        let third = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, date: { self.fixedDate })
        XCTAssertFalse(third.isEnabled)
        XCTAssertTrue(third.pendingEvents.isEmpty)
        await third.persistPendingEvents()
    }

    func testActiveAndReadingTransitionsDoNotDuplicateOnRerender() async {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let analytics = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, date: { self.fixedDate })
        analytics.setActive(true)
        analytics.setReadingContent(.epub)
        analytics.setReadingContent(.epub)
        analytics.setActive(true)
        XCTAssertEqual(analytics.pendingEvents.filter { $0.name == .appActive }.count, 1)
        XCTAssertEqual(analytics.pendingEvents.filter { $0.name == .readingStarted }.count, 1)
        let firstSession = analytics.pendingEvents.first?.sessionID
        analytics.setActive(false)
        analytics.setActive(true)
        XCTAssertEqual(analytics.pendingEvents.filter { $0.name == .appActive }.count, 2)
        XCTAssertEqual(analytics.pendingEvents.filter { $0.name == .readingStarted }.count, 2)
        XCTAssertNotEqual(analytics.pendingEvents.last?.sessionID, firstSession)
        await analytics.persistPendingEvents()
    }

    func testInputDoesNotProduceHeartbeatsUntilTimerAndIdleGapIsNotBackfilled() async {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        var uptime: TimeInterval = 0
        let analytics = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, uptime: { uptime }, date: { self.fixedDate })
        analytics.setActive(true)
        analytics.setReadingContent(.epub)
        for time in 1...14 { uptime = Double(time); analytics.recordInteraction() }
        XCTAssertTrue(analytics.pendingEvents.filter { $0.name == .readingHeartbeat }.isEmpty)
        uptime = 15; analytics.tick()
        XCTAssertEqual(analytics.pendingEvents.last?.durationSeconds, 15)
        for time in stride(from: 30, through: 150, by: 15) { uptime = Double(time); analytics.tick() }
        let beforeIdleResume = analytics.pendingEvents.compactMap(\.durationSeconds).reduce(0, +)
        XCTAssertEqual(beforeIdleResume, 134) // Last input at 14 + two-minute idle timeout.
        uptime = 600; analytics.recordInteraction()
        XCTAssertEqual(analytics.pendingEvents.compactMap(\.durationSeconds).reduce(0, +), beforeIdleResume)
        uptime = 615; analytics.tick()
        XCTAssertEqual(analytics.pendingEvents.last?.durationSeconds, 15)
        await analytics.persistPendingEvents()
    }

    func testDevelopmentAndTestCollectionGateNeverCreatesIdentifiersOrQueue() async {
        let (defaults, directory) = context()
        let analytics = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: false,
            networkAllowed: true, startTimer: false)
        analytics.setActive(true)
        analytics.record(.aiRequestStarted)
        analytics.tick()
        await analytics.persistPendingEvents()
        XCTAssertTrue(analytics.pendingEvents.isEmpty)
        XCTAssertNil(defaults.string(forKey: UsageAnalytics.installationKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(UsageAnalytics.defaultCollectionAllowed)
    }

    func testNonReadingWindowPausesTimeWhileRetainingSelectedContent() async {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        var uptime: TimeInterval = 0
        let analytics = UsageAnalytics(defaults: defaults, directory: directory, collectionAllowed: true,
            networkAllowed: false, startTimer: false, uptime: { uptime }, date: { self.fixedDate })
        analytics.setActive(true)
        analytics.setReadingContent(.pdf)
        uptime = 15; analytics.tick()
        analytics.setReadingWindowVisible(false)
        uptime = 60; analytics.tick()
        analytics.setReadingContent(.pdf) // A SwiftUI update cannot restart an obscured reader.
        uptime = 100; analytics.tick()
        XCTAssertEqual(analytics.pendingEvents.compactMap(\.durationSeconds).reduce(0, +), 15)
        analytics.setReadingWindowVisible(true)
        analytics.recordInteraction()
        uptime = 115; analytics.tick()
        XCTAssertEqual(analytics.pendingEvents.compactMap(\.durationSeconds).reduce(0, +), 30)
        XCTAssertEqual(analytics.pendingEvents.filter { $0.name == .appActive }.count, 1)
        XCTAssertEqual(analytics.pendingEvents.filter { $0.name == .readingStarted }.count, 2)
        await analytics.persistPendingEvents()
    }

    func testTransientUploadRetriesSameEventIDsWithoutAccountHeaders() async throws {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = AnalyticsUploadProbe(statuses: [503, 202])
        AnalyticsTestURLProtocol.probe = probe
        defer { AnalyticsTestURLProtocol.probe = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var uptime: TimeInterval = 0
        let analytics = UsageAnalytics(defaults: defaults, directory: directory,
            endpoint: URL(string: "https://analytics.invalid/api/analytics/events")!, session: session,
            collectionAllowed: true, networkAllowed: true, startTimer: false,
            uptime: { uptime }, date: { self.fixedDate })
        analytics.record(.aiRequestStarted, content: .epub)
        let originalID = try XCTUnwrap(analytics.pendingEvents.first?.id)
        analytics.flush()
        // Advance the injected monotonic clock so retries need no real backoff wait.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !analytics.pendingEvents.isEmpty {
            uptime += 1_000
            analytics.tick()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(analytics.pendingEvents.isEmpty)
        let requests = probe.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(request.httpBody)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?["id"] as? String, originalID.uuidString)
            XCTAssertEqual(events.first?["name"] as? String, "ai_request_started")
        }
        await analytics.persistPendingEvents()
    }

    func testOrdinaryUploadsWaitOneMinuteAndFullBatchesRemainPaced() async throws {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = AnalyticsUploadProbe(statuses: [202])
        AnalyticsTestURLProtocol.probe = probe
        defer { AnalyticsTestURLProtocol.probe = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var uptime: TimeInterval = 0
        let analytics = UsageAnalytics(defaults: defaults, directory: directory,
            endpoint: URL(string: "https://analytics.invalid/api/analytics/events")!, session: session,
            collectionAllowed: true, networkAllowed: true, startTimer: false,
            uptime: { uptime }, date: { self.fixedDate })
        analytics.record(.pageTurned); analytics.flush()
        for _ in 0..<100 where !analytics.pendingEvents.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(probe.requests.count, 1)
        analytics.record(.noteCreated)
        uptime = 59; analytics.tick()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(probe.requests.count, 1)
        uptime = 60; analytics.tick()
        for _ in 0..<100 where !analytics.pendingEvents.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(probe.requests.count, 2)
        for _ in 0..<100 { analytics.record(.pageTurned) }
        uptime = 61; analytics.flush()
        XCTAssertEqual(probe.requests.count, 2)
        uptime = 75; analytics.flush()
        for _ in 0..<100 where analytics.pendingEvents.count != 50 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(probe.requests.count, 3)
        XCTAssertEqual(analytics.pendingEvents.count, 50, "A full backlog must not recurse into an unbounded upload burst")
        uptime = 90; analytics.flush()
        for _ in 0..<100 where !analytics.pendingEvents.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(probe.requests.count, 4)
        for request in probe.requests {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertLessThanOrEqual(try XCTUnwrap(object["events"] as? [Any]).count, 50)
        }
        await analytics.persistPendingEvents()
    }

    func testOptOutDuringUploadCancelsAndDoesNotResurrectOldQueue() async throws {
        let (defaults, directory) = context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = AnalyticsUploadProbe(statuses: [202])
        AnalyticsTestURLProtocol.probe = probe
        AnalyticsTestURLProtocol.holdResponses = true
        defer { AnalyticsTestURLProtocol.probe = nil; AnalyticsTestURLProtocol.holdResponses = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let analytics = UsageAnalytics(defaults: defaults, directory: directory,
            endpoint: URL(string: "https://analytics.invalid/api/analytics/events")!, session: session,
            collectionAllowed: true, networkAllowed: true, startTimer: false, date: { self.fixedDate })
        analytics.record(.pageTurned)
        let oldID = try XCTUnwrap(analytics.pendingEvents.first?.installationID)
        analytics.flush()
        for _ in 0..<100 where probe.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(probe.requests.count, 1)
        analytics.setEnabled(false)
        await analytics.persistPendingEvents()
        XCTAssertTrue(analytics.pendingEvents.isEmpty)
        XCTAssertNil(defaults.string(forKey: UsageAnalytics.installationKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        analytics.setEnabled(true)
        analytics.record(.noteCreated)
        XCTAssertNotEqual(analytics.pendingEvents.first?.installationID, oldID)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(analytics.pendingEvents.map(\.name), [.noteCreated])
        await analytics.persistPendingEvents()
    }
}

private final class AnalyticsUploadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private let statuses: [Int]
    init(statuses: [Int]) { self.statuses = statuses }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    func capture(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        captured.append(request)
        return statuses[min(captured.count - 1, statuses.count - 1)]
    }
}

private final class AnalyticsTestURLProtocol: URLProtocol, @unchecked Sendable {
    static var probe: AnalyticsUploadProbe?
    static var holdResponses = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            captured.httpBody = body
        }
        let status = Self.probe?.capture(captured) ?? 500
        if Self.holdResponses { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"accepted\":1}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
