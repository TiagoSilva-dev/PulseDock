import Foundation

/// Applies events to sessions deterministically, tolerating duplicates and out-of-order
/// delivery.
///
/// Each session keeps a bounded, ordered buffer of recent events plus a *baseline* (the
/// session as it was before the oldest buffered event). In-order events are applied
/// incrementally; a late event is inserted at its place and the session is recomputed by
/// folding the buffer over the baseline, so the result never depends on arrival order.
///
/// Not thread-safe: own it from a single isolation domain (the app uses the main actor).
public final class AgentSessionEngine {
    public struct Configuration: Sendable {
        public var maxBufferedEventsPerSession: Int
        public var duplicateWindow: TimeInterval
        public var rememberedEventIDs: Int

        /// `duplicateWindow` is short on purpose: real duplicates (the same hook registered twice
        /// under different commands) arrive within milliseconds of each other.
        public init(maxBufferedEventsPerSession: Int = 400, duplicateWindow: TimeInterval = 0.25, rememberedEventIDs: Int = 5000) {
            self.maxBufferedEventsPerSession = maxBufferedEventsPerSession
            self.duplicateWindow = duplicateWindow
            self.rememberedEventIDs = rememberedEventIDs
        }
    }

    public enum IngestOutcome: Equatable, Sendable {
        case applied
        case reordered
        case duplicate
        case rejected(String)
    }

    private struct SessionLog {
        var baseline: AgentSession
        var events: [AgentEvent]
    }

    public let configuration: Configuration
    public private(set) var sessions: [SessionKey: AgentSession] = [:]
    private var logs: [SessionKey: SessionLog] = [:]
    private var seenIDs = BoundedSet<String>(capacity: 5000)
    private var recentFingerprints: [String: Date] = [:]
    private var sequence: UInt64 = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.seenIDs = BoundedSet(capacity: configuration.rememberedEventIDs)
    }

    // MARK: Ingest

    @discardableResult
    public func ingest(_ incoming: AgentEvent) -> IngestOutcome {
        guard !incoming.sessionID.isEmpty else { return .rejected("missing_session_id") }
        guard incoming.schemaVersion <= AgentEvent.currentSchemaVersion else { return .rejected("unsupported_schema") }
        if seenIDs.contains(incoming.id) { return .duplicate }

        if incoming.kind != .heartbeat {
            let fingerprint = incoming.contentFingerprint
            if let previous = recentFingerprints[fingerprint],
               abs(incoming.occurredAt.timeIntervalSince(previous)) < configuration.duplicateWindow {
                seenIDs.insert(incoming.id)
                return .duplicate
            }
            recentFingerprints[fingerprint] = incoming.occurredAt
            if recentFingerprints.count > 2000 { pruneFingerprints(now: incoming.occurredAt) }
        }
        seenIDs.insert(incoming.id)

        var event = incoming
        sequence += 1
        event.order.sequence = sequence

        let key = event.sessionKey
        var log = logs[key] ?? SessionLog(baseline: AgentSession(key: key, firstSeenAt: event.occurredAt), events: [])
        let outcome: IngestOutcome
        let session: AgentSession
        if let last = log.events.last, event.order < last.order {
            let index = log.events.firstIndex { event.order < $0.order } ?? log.events.endIndex
            log.events.insert(event, at: index)
            if index == 0 {
                log.baseline.firstSeenAt = min(log.baseline.firstSeenAt, event.occurredAt)
            }
            session = log.events.reduce(log.baseline) { SessionReducer.apply($1, to: $0) }
            outcome = .reordered
        } else {
            log.events.append(event)
            session = SessionReducer.apply(event, to: sessions[key] ?? log.baseline)
            outcome = .applied
        }
        while log.events.count > configuration.maxBufferedEventsPerSession {
            let oldest = log.events.removeFirst()
            log.baseline = SessionReducer.apply(oldest, to: log.baseline)
        }
        logs[key] = log
        sessions[key] = session
        return outcome
    }

    /// Ingests a batch and returns the keys of sessions that changed.
    @discardableResult
    public func ingest(_ events: [AgentEvent]) -> Set<SessionKey> {
        var changed = Set<SessionKey>()
        for event in events {
            switch ingest(event) {
            case .applied, .reordered: changed.insert(event.sessionKey)
            case .duplicate, .rejected: break
            }
        }
        return changed
    }

    // MARK: Queries

    public func session(_ key: SessionKey) -> AgentSession? { sessions[key] }

    /// Recent in-memory events of a session in order (bounded by the buffer size).
    public func bufferedEvents(for key: SessionKey) -> [AgentEvent] {
        logs[key]?.events ?? []
    }

    // MARK: Lifecycle management

    /// Restores sessions persisted from a previous run. Their event buffers start empty;
    /// new events apply on top of the restored snapshot.
    public func restore(_ restored: [AgentSession]) {
        for session in restored where sessions[session.key] == nil {
            sessions[session.key] = session
            logs[session.key] = SessionLog(baseline: session, events: [])
        }
    }

    public func remove(_ key: SessionKey) {
        sessions.removeValue(forKey: key)
        logs.removeValue(forKey: key)
    }

    public func removeAll(where predicate: (AgentSession) -> Bool) {
        for (key, session) in sessions where predicate(session) {
            remove(key)
        }
    }

    /// Synthesises `processExited` for active sessions whose agent process is known to be
    /// gone, ingests them, and returns them (so they can be persisted and shown).
    public func reconcileProcessLiveness(now: Date, isAlive: (AgentSession) -> Bool?) -> [AgentEvent] {
        var synthesized: [AgentEvent] = []
        for session in sessions.values where session.lifecycle == .active {
            guard isAlive(session) == false else { continue }
            let event = AgentEvent(
                id: "reconcile-exit-\(session.key.rawValue)-\(Int(now.timeIntervalSince1970))",
                provider: session.provider,
                sessionID: session.sessionID,
                kind: .processExited,
                receivedAt: now,
                order: EventOrder(date: now),
                collection: .reconciliation,
                confidence: .inferred,
                sourceEvent: "ProcessExit",
                metadata: ["reason": "process_exited"]
            )
            if ingest(event) != .duplicate {
                synthesized.append(event)
            }
        }
        return synthesized.sorted { $0.order < $1.order }
    }

    private func pruneFingerprints(now: Date) {
        let limit = configuration.duplicateWindow * 4
        recentFingerprints = recentFingerprints.filter { now.timeIntervalSince($0.value) < limit }
    }
}

/// FIFO set with a fixed capacity.
struct BoundedSet<Element: Hashable> {
    private var members = Set<Element>()
    private var order: [Element] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func contains(_ element: Element) -> Bool { members.contains(element) }

    mutating func insert(_ element: Element) {
        guard members.insert(element).inserted else { return }
        order.append(element)
        if members.count > capacity {
            members.remove(order[head])
            head += 1
            if head > capacity {
                order.removeFirst(head)
                head = 0
            }
        }
    }
}
