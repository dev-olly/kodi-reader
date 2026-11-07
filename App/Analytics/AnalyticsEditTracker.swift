import Foundation

enum AnalyticsEditKind: Hashable { case note, sketch }

/// A local save checkpoint. Item identifiers are deliberately absent from both
/// the token and the resulting AnalyticsEvent payload.
struct AnalyticsEditToken: Equatable, Hashable {
    fileprivate let id: UUID
    fileprivate let generation: UUID
}

/// Counts meaningful successful edits rather than autosaves. Closed sessions
/// remain briefly available for asynchronous persistence completions, bounded to
/// 512 checkpoints. Clearing consent invalidates every previous checkpoint.
struct AnalyticsEditTracker {
    private struct Session {
        let token: AnalyticsEditToken
        let kind: AnalyticsEditKind
        let itemKey: String
        let isNew: Bool
        let content: AnalyticsContentType?
        var lastInteraction: TimeInterval
        var emitted = false
    }

    struct Emission: Equatable {
        let name: AnalyticsEventName
        let content: AnalyticsContentType?
    }

    private var generation = UUID()
    private var sessions: [UUID: Session] = [:]
    private var order: [UUID] = []
    private var active: [AnalyticsEditKind: UUID] = [:]

    /// No item key or activity timing is retained when collection is disabled.
    func inactiveToken() -> AnalyticsEditToken { AnalyticsEditToken(id: UUID(), generation: UUID()) }

    mutating func begin(kind: AnalyticsEditKind, itemKey: String, isNew: Bool,
                        content: AnalyticsContentType?, now: TimeInterval) -> AnalyticsEditToken {
        expireIdle(at: now)
        if let id = active[kind], let session = sessions[id], session.itemKey == itemKey {
            return session.token
        }
        let token = AnalyticsEditToken(id: UUID(), generation: generation)
        let wasCreated = sessions.values.contains {
            $0.kind == kind && $0.itemKey == itemKey && $0.isNew && $0.emitted
        }
        sessions[token.id] = Session(token: token, kind: kind, itemKey: itemKey,
                                     isNew: isNew && !wasCreated, content: content, lastInteraction: now)
        order.append(token.id)
        active[kind] = token.id
        while order.count > 512 {
            let removed = order.removeFirst()
            sessions.removeValue(forKey: removed)
            active = active.filter { $0.value != removed }
        }
        return token
    }

    mutating func didPersist(_ token: AnalyticsEditToken, meaningful: Bool) -> Emission? {
        guard meaningful, token.generation == generation,
              var session = sessions[token.id], !session.emitted else { return nil }
        let creationAlreadyReported = session.isNew && sessions.values.contains {
            $0.token != token && $0.kind == session.kind && $0.itemKey == session.itemKey && $0.isNew && $0.emitted
        }
        session.emitted = true
        sessions[token.id] = session
        // Two focus sessions can be waiting on the same initial asynchronous
        // write. Whichever succeeds first records the single creation.
        guard !creationAlreadyReported else { return nil }
        let name: AnalyticsEventName
        switch (session.kind, session.isNew) {
        case (.note, true): name = .noteCreated
        case (.note, false): name = .noteEditSession
        case (.sketch, true): name = .sketchCreated
        case (.sketch, false): name = .sketchEditSession
        }
        return Emission(name: name, content: session.content)
    }

    mutating func end(_ token: AnalyticsEditToken) {
        guard token.generation == generation else { return }
        active = active.filter { $0.value != token.id }
    }

    mutating func endAll() { active.removeAll() }

    mutating func interacted(at now: TimeInterval) {
        expireIdle(at: now)
        for id in active.values { sessions[id]?.lastInteraction = now }
    }

    mutating func expireIdle(at now: TimeInterval) {
        active = active.filter { _, id in
            guard let session = sessions[id] else { return false }
            return now >= session.lastInteraction && now - session.lastInteraction < AnalyticsReadingClock.idleTimeout
        }
    }

    mutating func reset() {
        generation = UUID()
        sessions.removeAll()
        order.removeAll()
        active.removeAll()
    }
}
