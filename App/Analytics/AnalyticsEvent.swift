import Foundation

/// A deliberately closed schema: free-form strings and document identifiers
/// cannot enter telemetry through an arbitrary properties dictionary.
enum AnalyticsEventName: String, Codable, CaseIterable, Sendable {
    case appActive = "app_active"
    case readingStarted = "reading_started"
    case readingHeartbeat = "reading_heartbeat"
    case pageTurned = "page_turned"
    case bookImported = "book_imported"
    case highlightCreated = "highlight_created"
    case noteSaved = "note_saved"
    case sketchSaved = "sketch_saved"
    case noteCreated = "note_created"
    case noteEditSession = "note_edit_session"
    case sketchCreated = "sketch_created"
    case sketchEditSession = "sketch_edit_session"
    case webOpened = "web_opened"
    case aiRequestStarted = "ai_request_started"
    case aiRequestCompleted = "ai_request_completed"
    case aiRequestFailed = "ai_request_failed"
    case aiRequestCancelled = "ai_request_cancelled"
}

enum AnalyticsContentType: String, Codable, Sendable { case epub, pdf, web }
enum AnalyticsErrorCategory: String, Codable, Sendable { case network, authentication, credits, service }

struct AnalyticsEvent: Codable, Equatable, Sendable {
    struct Properties: Codable, Equatable, Sendable {
        let platform: String
        let version: String
        let build: String
        let contentType: AnalyticsContentType?
        let errorCategory: AnalyticsErrorCategory?
        let requestID: UUID?
        let schemaVersion: Int

        init(platform: String, version: String, build: String,
             contentType: AnalyticsContentType?, errorCategory: AnalyticsErrorCategory?,
             requestID: UUID? = nil, schemaVersion: Int = 2) {
            self.platform = platform
            self.version = version
            self.build = build
            self.contentType = contentType
            self.errorCategory = errorCategory
            self.requestID = requestID
            self.schemaVersion = schemaVersion
        }

        enum CodingKeys: String, CodingKey {
            case platform, version, build
            case contentType = "content_type"
            case errorCategory = "error_category"
            case requestID = "request_id"
            case schemaVersion = "schema_version"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            platform = try values.decode(String.self, forKey: .platform)
            version = try values.decode(String.self, forKey: .version)
            build = try values.decode(String.self, forKey: .build)
            contentType = try values.decodeIfPresent(AnalyticsContentType.self, forKey: .contentType)
            errorCategory = try values.decodeIfPresent(AnalyticsErrorCategory.self, forKey: .errorCategory)
            requestID = try values.decodeIfPresent(UUID.self, forKey: .requestID)
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }
    }

    let id: UUID
    let installationID: UUID
    let sessionID: UUID
    let occurredAt: Date
    let name: AnalyticsEventName
    let durationSeconds: Int?
    let properties: Properties

    enum CodingKeys: String, CodingKey {
        case id, name, properties
        case installationID = "installation_id"
        case sessionID = "session_id"
        case occurredAt = "occurred_at"
        case durationSeconds = "duration_seconds"
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Retry IDs stay unchanged. Oldest events are evicted first while offline.
struct AnalyticsOutbox {
    static let maximumCount = 500
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    private(set) var events: [AnalyticsEvent] = []

    init(events: [AnalyticsEvent] = [], now: Date = Date()) {
        var seen = Set<UUID>()
        self.events = Array(events.filter {
            $0.occurredAt >= now.addingTimeInterval(-Self.retention)
                && $0.occurredAt <= now.addingTimeInterval(300)
                && seen.insert($0.id).inserted
        }.suffix(Self.maximumCount))
    }

    mutating func append(_ event: AnalyticsEvent, now: Date) {
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
        self = Self(events: events, now: now)
    }

    mutating func acknowledge(_ ids: Set<UUID>) { events.removeAll { ids.contains($0.id) } }
    mutating func removeAll() { events.removeAll() }
}

/// Monotonic time prevents wall-clock changes from inflating reading duration.
/// Each advance is capped at 60 seconds, including delayed timers after sleep.
struct AnalyticsReadingClock {
    static let idleTimeout: TimeInterval = 120
    private(set) var isActive = false
    private(set) var content: AnalyticsContentType?
    private var lastTick: TimeInterval
    private var lastInteraction: TimeInterval
    private var fractionalSeconds: TimeInterval = 0

    init(now: TimeInterval) { lastTick = now; lastInteraction = now }

    mutating func advance(to now: TimeInterval) -> Int {
        defer { lastTick = now }
        guard isActive, content != nil, now >= lastTick else { return 0 }
        let end = min(now, lastInteraction + Self.idleTimeout)
        let elapsed = min(60, max(0, end - lastTick)) + fractionalSeconds
        let seconds = min(60, Int(elapsed))
        fractionalSeconds = elapsed - Double(seconds)
        return seconds
    }

    mutating func setActive(_ active: Bool, now: TimeInterval) {
        isActive = active; lastTick = now; lastInteraction = now
        fractionalSeconds = 0
    }

    mutating func setContent(_ content: AnalyticsContentType?, now: TimeInterval) {
        self.content = content; lastTick = now; fractionalSeconds = 0
    }

    mutating func interacted(at now: TimeInterval) { lastInteraction = now }
    func hasIdleGap(at now: TimeInterval) -> Bool { now > lastInteraction + Self.idleTimeout }
}
