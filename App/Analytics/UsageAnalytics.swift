import Foundation
import Observation

/// Best-effort analytics is independent of authentication, sync, and reading.
/// No cookies or account authorization are attached to its requests.
@MainActor
@Observable
final class UsageAnalytics {
    static let consentKey = "kodi.analytics.enabled"
    static let installationKey = "kodi.analytics.installationID"
    static let shared = UsageAnalytics()

    private(set) var isEnabled: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storage: AnalyticsStorage
    @ObservationIgnored private let endpoint: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let collectionAllowed: Bool
    @ObservationIgnored private let networkAllowed: Bool
    @ObservationIgnored private let version: String
    @ObservationIgnored private let build: String
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private let date: () -> Date
    @ObservationIgnored private var installationID: UUID?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var outbox: AnalyticsOutbox
    @ObservationIgnored private var clock: AnalyticsReadingClock
    @ObservationIgnored private var featureClocks: [AnalyticsFeatureActivity: AnalyticsFeatureClock] = [:]
    @ObservationIgnored private var selectedReadingContent: AnalyticsContentType?
    @ObservationIgnored private var readingWindowVisible = true
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var nextAttempt: TimeInterval = 0
    @ObservationIgnored private var failureCount = 0
    @ObservationIgnored private var lastUploadAt: TimeInterval?
    @ObservationIgnored private var edits = AnalyticsEditTracker()
    @ObservationIgnored private var activeRequestIDs: Set<UUID> = []

    init(defaults: UserDefaults = .standard,
         directory: URL = AppDataDirectory.root.appendingPathComponent("Analytics", isDirectory: true),
         endpoint: URL? = nil, session: URLSession? = nil,
         collectionAllowed: Bool = UsageAnalytics.defaultCollectionAllowed,
         networkAllowed: Bool = true, startTimer: Bool = true,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         date: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.collectionAllowed = collectionAllowed
        self.networkAllowed = networkAllowed
        self.uptime = uptime
        self.date = date
        self.endpoint = endpoint ?? Self.configuredEndpoint
        version = String((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown").prefix(32))
        let rawBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        build = !rawBuild.isEmpty && rawBuild.count <= 32 && rawBuild.allSatisfy({ $0.isASCII && $0.isNumber }) ? rawBuild : "0"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration)
        storage = AnalyticsStorage(directory: directory)
        let consent = defaults.object(forKey: Self.consentKey) as? Bool ?? true
        isEnabled = consent
        clock = AnalyticsReadingClock(now: uptime())
        outbox = AnalyticsOutbox(events: consent && collectionAllowed ? storage.load() : [], now: date())
        if isEnabled && collectionAllowed {
            installationID = defaults.string(forKey: Self.installationKey).flatMap(UUID.init(uuidString:)) ?? UUID()
            defaults.set(installationID?.uuidString, forKey: Self.installationKey)
            storage.save(outbox.events)
        } else {
            installationID = nil
            if !isEnabled { defaults.removeObject(forKey: Self.installationKey); storage.remove() }
        }
        if startTimer && collectionAllowed {
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer?.tolerance = 2
        }
    }

    nonisolated static var defaultCollectionAllowed: Bool {
        #if DEBUG || KODI_PAYMENT_SANDBOX
        return false
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && NSClassFromString("XCTestCase") == nil
        #endif
    }

    private static var configuredEndpoint: URL {
        if let value = Bundle.main.object(forInfoDictionaryKey: "KodiAnalyticsURL") as? String,
           let url = URL(string: value), url.scheme == "https", url.host != nil,
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil { return url }
        return URL(string: "https://www.kodi-reader.app/api/analytics/events")!
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.consentKey)
        generation = UUID()
        uploadTask?.cancel(); uploadTask = nil
        outbox.removeAll()
        edits.reset()
        activeRequestIDs.removeAll()
        nextAttempt = 0; failureCount = 0
        lastUploadAt = nil
        defaults.removeObject(forKey: Self.installationKey)
        installationID = nil
        storage.remove()
        clock.setActive(clock.isActive, now: uptime())
        for activity in AnalyticsFeatureActivity.allCases { featureClocks[activity]?.reset(now: uptime()) }
        guard enabled && collectionAllowed else { return }
        installationID = UUID()
        defaults.set(installationID?.uuidString, forKey: Self.installationKey)
        sessionID = UUID()
        if clock.isActive {
            record(.appActive)
            if let content = clock.content { record(.readingStarted, content: content) }
        }
        flush()
    }

    func setActive(_ active: Bool) {
        guard active != clock.isActive else { return }
        heartbeat()
        if !active { edits.endAll() }
        clock.setActive(active, now: uptime())
        if active {
            sessionID = UUID()
            record(.appActive)
            if let content = clock.content { record(.readingStarted, content: content) }
        }
        flush()
    }

    func setReadingContent(_ content: AnalyticsContentType?) {
        selectedReadingContent = content
        updateReadingContent()
    }

    func setReadingWindowVisible(_ visible: Bool) {
        guard visible != readingWindowVisible else { return }
        readingWindowVisible = visible
        if !visible { edits.endAll() }
        updateReadingContent()
    }

    private func updateReadingContent() {
        let content = readingWindowVisible ? selectedReadingContent : nil
        guard content != clock.content else { return }
        heartbeat()
        clock.setContent(content, now: uptime())
        if clock.isActive, let content { record(.readingStarted, content: content) }
    }

    func recordInteraction() {
        // Account for the interval before resuming, so idle time is never backfilled.
        if clock.hasIdleGap(at: uptime()) { heartbeat() }
        edits.interacted(at: uptime())
        clock.interacted(at: uptime())
    }

    func record(_ name: AnalyticsEventName, content: AnalyticsContentType? = nil,
                error: AnalyticsErrorCategory? = nil, requestID: UUID? = nil,
                timing: AnalyticsAIRequestTiming? = nil) {
        guard isEnabled, collectionAllowed else { return }
        // Duration events can only come from their bounded monotonic clocks.
        guard ![.readingHeartbeat, .audioRecordingHeartbeat, .ttsListeningHeartbeat].contains(name) else { return }
        if let requestID {
            switch name {
            case .aiRequestStarted:
                guard activeRequestIDs.insert(requestID).inserted else { return }
            case .aiRequestCompleted, .aiRequestFailed, .aiRequestCancelled:
                // An opt-out/identity reset during a stream must not link its
                // old request to a newly enabled installation identifier.
                guard activeRequestIDs.remove(requestID) != nil else { return }
            default: return
            }
        }
        let isTerminal = [.aiRequestCompleted, .aiRequestFailed, .aiRequestCancelled].contains(name)
        // Timing is useful only on a correlated outcome. A completion without
        // first text remains an outcome, but cannot supply a completed sample.
        let validTiming = isTerminal && requestID != nil
            && (name != .aiRequestCompleted || timing?.latencyMilliseconds != nil) ? timing : nil
        enqueue(name, content: content, error: error, duration: nil, requestID: requestID, timing: validTiming)
    }

    func beginEditing(kind: AnalyticsEditKind, itemKey: String, isNew: Bool,
                      content: AnalyticsContentType? = nil) -> AnalyticsEditToken {
        guard isEnabled, collectionAllowed else { return edits.inactiveToken() }
        return edits.begin(kind: kind, itemKey: itemKey, isNew: isNew, content: content, now: uptime())
    }

    func noteSuccessfulEdit(token: AnalyticsEditToken, meaningful: Bool) {
        guard isEnabled, collectionAllowed else { return }
        if let event = edits.didPersist(token, meaningful: meaningful) {
            record(event.name, content: event.content)
        }
    }

    func endEditing(token: AnalyticsEditToken) { edits.end(token) }
    func endAllEditing() { edits.endAll() }

    func setFeatureActivity(_ activity: AnalyticsFeatureActivity, active: Bool) {
        let now = uptime()
        var featureClock = featureClocks[activity] ?? AnalyticsFeatureClock(now: now)
        guard featureClock.isActive != active else { return }
        let seconds = featureClock.advance(to: now)
        if seconds > 0 { enqueue(activity.heartbeatEvent, content: nil, error: nil, duration: seconds) }
        featureClock.setActive(active, now: now)
        featureClocks[activity] = featureClock
    }

    func tick() { heartbeat(); featureHeartbeat(); edits.expireIdle(at: uptime()); flush() }

    /// A quit checkpoint waits only for local disk writes, never the network.
    func persistPendingEvents() async {
        featureHeartbeat()
        await storage.waitForPendingWrites()
    }

    private func featureHeartbeat() {
        let now = uptime()
        for activity in AnalyticsFeatureActivity.allCases {
            guard var featureClock = featureClocks[activity] else { continue }
            let seconds = featureClock.advance(to: now)
            featureClocks[activity] = featureClock
            if seconds > 0 { enqueue(activity.heartbeatEvent, content: nil, error: nil, duration: seconds) }
        }
    }

    private func heartbeat() {
        let content = clock.content
        let seconds = clock.advance(to: uptime())
        if seconds > 0 { enqueue(.readingHeartbeat, content: content, error: nil, duration: seconds) }
    }

    private func enqueue(_ name: AnalyticsEventName, content: AnalyticsContentType?,
                         error: AnalyticsErrorCategory?, duration: Int?, requestID: UUID? = nil,
                         timing: AnalyticsAIRequestTiming? = nil) {
        guard isEnabled, collectionAllowed, let installationID else { return }
        let event = AnalyticsEvent(id: UUID(), installationID: installationID, sessionID: sessionID,
            occurredAt: date(), name: name, durationSeconds: duration,
            properties: .init(platform: "macOS", version: version, build: build,
                              contentType: content, errorCategory: error, requestID: requestID, timing: timing))
        outbox.append(event, now: date())
        storage.save(outbox.events)
    }

    func flush() {
        guard isEnabled, collectionAllowed, networkAllowed, uploadTask == nil,
              uptime() >= nextAttempt else { return }
        // Apply retention again after a long-running offline app session.
        outbox = AnalyticsOutbox(events: outbox.events, now: date())
        guard !outbox.events.isEmpty else { storage.save([]); return }
        if let lastUploadAt {
            let sinceUpload = uptime() - lastUploadAt
            // Ordinary activity uses one background upload a minute. A full
            // batch can leave sooner, bounded to four batches a minute, below
            // the collector's per-installation rate limit.
            guard sinceUpload >= 60 || (outbox.events.count >= 50 && sinceUpload >= 15) else { return }
        }
        let batch = Array(outbox.events.prefix(50))
        let generation = generation
        struct Batch: Encodable { let events: [AnalyticsEvent] }
        guard let body = try? AnalyticsEvent.encoder().encode(Batch(events: batch)) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        lastUploadAt = uptime()
        uploadTask = Task { [weak self, session] in
            let status: Int?
            do { status = (try await session.data(for: request).1 as? HTTPURLResponse)?.statusCode }
            catch { status = nil }
            guard let self, self.generation == generation, self.isEnabled, !Task.isCancelled else { return }
            self.uploadTask = nil
            if let status, (200...299).contains(status) || status == 400 || status == 413 {
                // Bad batches are discarded rather than retried indefinitely.
                self.outbox.acknowledge(Set(batch.map(\.id)))
                self.storage.save(self.outbox.events)
                self.failureCount = 0; self.nextAttempt = 0
                self.flush()
            } else {
                self.failureCount = min(5, self.failureCount + 1)
                self.nextAttempt = self.uptime() + min(300, 15 * pow(2, Double(self.failureCount)))
            }
        }
    }

    // Internal read-only snapshots support deterministic privacy/lifecycle tests.
    var pendingEvents: [AnalyticsEvent] { outbox.events }
}

/// Disk writes are serialized off the main thread. Clearing consent is ordered
/// after all previous snapshots, so an old write cannot resurrect the queue.
private final class AnalyticsStorage: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "app.kodi.analytics-storage", qos: .utility)
    private var file: URL { directory.appendingPathComponent("events.json") }

    init(directory: URL) { self.directory = directory }
    func load() -> [AnalyticsEvent] {
        queue.sync {
            guard let data = try? Data(contentsOf: file), data.count <= 1_000_000 else { return [] }
            return (try? AnalyticsEvent.decoder().decode([AnalyticsEvent].self, from: data)) ?? []
        }
    }
    func save(_ events: [AnalyticsEvent]) {
        queue.async { [self] in
            guard let data = try? AnalyticsEvent.encoder().encode(events) else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { /* Telemetry must never interrupt reading. */ }
        }
    }
    func remove() { queue.async { [self] in try? FileManager.default.removeItem(at: directory) } }
    func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
