import AgentCore
import Diagnostics
import Foundation

/// What may be written to disk, from Settings › Privacy.
public struct PersistencePolicy: Codable, Sendable, Hashable {
    /// Keep a local history of sessions and events.
    public var storeHistory: Bool
    /// Keep project paths in the history (off: only project names derived at runtime).
    public var storePaths: Bool
    public var retentionDays: Int

    public init(storeHistory: Bool = true, storePaths: Bool = true, retentionDays: Int = 14) {
        self.storeHistory = storeHistory
        self.storePaths = storePaths
        self.retentionDays = max(1, retentionDays)
    }
}

/// Filters for the AI Mission Control history.
public struct HistoryQuery: Sendable, Hashable {
    public var providers: Set<AgentProvider>
    public var states: Set<SessionState>
    public var projectPath: String?
    public var text: String?
    public var from: Date?
    public var to: Date?
    public var limit: Int

    public init(providers: Set<AgentProvider> = [], states: Set<SessionState> = [], projectPath: String? = nil,
                text: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int = 200) {
        self.providers = providers
        self.states = states
        self.projectPath = projectPath
        self.text = text
        self.from = from
        self.to = to
        self.limit = limit
    }
}

/// Owns the SQLite database on a private serial queue. All writes are asynchronous; reads
/// used by the UI are asynchronous too, so the main thread never waits on disk.
public final class PersistenceController: @unchecked Sendable {
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = ProcessInfo.processInfo.environment["PULSEDOCK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? base.appendingPathComponent("PulseDock", isDirectory: true)
        return root.appendingPathComponent("pulsedock.sqlite")
    }

    private let queue = DispatchQueue(label: "app.pulsedock.persistence", qos: .utility)
    private let database: SQLiteDatabase
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    public let url: URL?

    public init(url: URL? = PersistenceController.defaultURL) throws {
        self.url = url
        database = try SQLiteDatabase(url: url)
        try Migrations.migrate(database)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    public var schemaVersion: Int { queue.sync { database.userVersion } }

    // MARK: Settings (key → JSON)

    public func loadSetting<T: Decodable & Sendable>(_ type: T.Type, key: String) -> T? {
        queue.sync {
            let json = try? database.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { $0.text(0) }.first
            guard let json, let data = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    public func saveSetting<T: Encodable & Sendable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) else { return }
        queue.async { [database] in
            do {
                try database.run(
                    "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                    [.text(key), .text(json), .real(Date().timeIntervalSince1970)]
                )
            } catch {
                PulseLog.persistence.error("Saving setting failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func removeSetting(key: String) {
        queue.async { [database] in try? database.run("DELETE FROM settings WHERE key = ?", [.text(key)]) }
    }

    // MARK: Events and sessions

    /// Persists events and the sessions they changed. Demo sessions are never written.
    public func record(events: [AgentEvent], sessions: [AgentSession], policy: PersistencePolicy) {
        guard policy.storeHistory else { return }
        let realEvents = events.filter { $0.collection != .fixture && $0.provider != .demo }
        let realSessions = sessions.filter { !$0.isDemo }
        guard !realEvents.isEmpty || !realSessions.isEmpty else { return }
        let encodedEvents: [(AgentEvent, String)] = realEvents.compactMap { event in
            let stored = policy.storePaths ? event : Self.strippingPaths(event)
            guard let data = try? encoder.encode(stored), let json = String(data: data, encoding: .utf8) else { return nil }
            return (stored, json)
        }
        let encodedSessions: [(AgentSession, String)] = realSessions.compactMap { session in
            let stored = policy.storePaths ? session : Self.strippingPaths(session)
            guard let data = try? encoder.encode(stored), let json = String(data: data, encoding: .utf8) else { return nil }
            return (stored, json)
        }
        queue.async { [database] in
            do {
                try database.transaction {
                    for (event, json) in encodedEvents {
                        try database.run("""
                        INSERT OR IGNORE INTO events(id, session_key, provider, kind, occurred_at, received_at, order_wall, order_mono, boot,
                                                     collection, confidence, project_path, payload)
                        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [
                            .text(event.id), .text(event.sessionKey.rawValue), .text(event.provider.rawValue), .text(event.kind.rawValue),
                            .real(event.occurredAt.timeIntervalSince1970), .real(event.receivedAt.timeIntervalSince1970),
                            .integer(event.order.wallMillis), .optional(event.order.monotonicNanos.map { Int64(bitPattern: $0) }),
                            .optional(event.order.bootID), .text(event.collection.rawValue), .text(event.confidence.rawValue),
                            .optional(event.projectPath), .text(json),
                        ])
                    }
                    for (session, json) in encodedSessions {
                        try database.run("""
                        INSERT INTO sessions(session_key, provider, session_id, project_path, title, state, lifecycle, started_at,
                                             first_seen_at, last_event_at, ended_at, event_count, snapshot)
                        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(session_key) DO UPDATE SET
                            project_path = excluded.project_path, title = excluded.title, state = excluded.state,
                            lifecycle = excluded.lifecycle, started_at = excluded.started_at, last_event_at = excluded.last_event_at,
                            ended_at = excluded.ended_at, event_count = excluded.event_count, snapshot = excluded.snapshot
                        """, [
                            .text(session.key.rawValue), .text(session.provider.rawValue), .text(session.sessionID),
                            .optional(session.projectPath), .optional(session.title), .text(session.state.rawValue),
                            .text(session.lifecycle.rawValue), .optional(session.startedAt?.timeIntervalSince1970),
                            .real(session.firstSeenAt.timeIntervalSince1970), .real(session.lastEventAt.timeIntervalSince1970),
                            .optional(session.endedAt?.timeIntervalSince1970), .integer(Int64(session.eventCount)), .text(json),
                        ])
                    }
                }
            } catch {
                PulseLog.persistence.error("Recording events failed: \(String(describing: error), privacy: .public)")
                DiagnosticsRecorder.shared.record(.error, "persistence", "record failed: \(error)")
            }
        }
    }

    /// Sessions seen since `date` (used to restore state at launch).
    public func sessions(since date: Date) async -> [AgentSession] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let sessions = (try? database.query(
                    "SELECT snapshot FROM sessions WHERE last_event_at >= ? ORDER BY last_event_at DESC LIMIT 500",
                    [.real(date.timeIntervalSince1970)]
                ) { row in row.text(0).flatMap(self.decodeSession) }) ?? []
                continuation.resume(returning: sessions)
            }
        }
    }

    public func history(_ query: HistoryQuery) async -> [AgentSession] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var clauses: [String] = []
                var values: [SQLValue] = []
                if !query.providers.isEmpty {
                    clauses.append("provider IN (\(query.providers.map { _ in "?" }.joined(separator: ",")))")
                    values += query.providers.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
                }
                if !query.states.isEmpty {
                    clauses.append("state IN (\(query.states.map { _ in "?" }.joined(separator: ",")))")
                    values += query.states.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
                }
                if let project = query.projectPath {
                    clauses.append("project_path = ?")
                    values.append(.text(project))
                }
                if let text = query.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                    clauses.append("(project_path LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\' OR session_id LIKE ? ESCAPE '\\')")
                    let pattern = "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
                    values += [.text(pattern), .text(pattern), .text(pattern)]
                }
                if let from = query.from {
                    clauses.append("last_event_at >= ?")
                    values.append(.real(from.timeIntervalSince1970))
                }
                if let to = query.to {
                    clauses.append("first_seen_at <= ?")
                    values.append(.real(to.timeIntervalSince1970))
                }
                let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
                values.append(.integer(Int64(query.limit)))
                let sessions = (try? database.query(
                    "SELECT snapshot FROM sessions \(filter) ORDER BY last_event_at DESC LIMIT ?", values
                ) { row in row.text(0).flatMap(self.decodeSession) }) ?? []
                continuation.resume(returning: sessions)
            }
        }
    }

    /// Events of a session in chronological order (optionally filtered by kind).
    public func events(for key: SessionKey, kinds: Set<AgentEventKind> = [], limit: Int = 2000) async -> [AgentEvent] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var sql = "SELECT payload FROM events WHERE session_key = ?"
                var values: [SQLValue] = [.text(key.rawValue)]
                if !kinds.isEmpty {
                    sql += " AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
                    values += kinds.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
                }
                sql += " ORDER BY order_wall DESC, rowid DESC LIMIT ?"
                values.append(.integer(Int64(limit)))
                let events = (try? database.query(sql, values) { row in row.text(0).flatMap(self.decodeEvent) }) ?? []
                continuation.resume(returning: events.sorted { $0.order < $1.order })
            }
        }
    }

    public struct Statistics: Sendable, Equatable {
        public var sessions: Int
        public var events: Int
        public var fileBytes: Int64
    }

    public func statistics() async -> Statistics {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let sessions = ((try? database.scalarInt("SELECT COUNT(*) FROM sessions")) ?? nil) ?? 0
                let events = ((try? database.scalarInt("SELECT COUNT(*) FROM events")) ?? nil) ?? 0
                var bytes: Int64 = 0
                if let url {
                    for suffix in ["", "-wal", "-shm"] {
                        let path = url.path + suffix
                        bytes += ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
                    }
                }
                continuation.resume(returning: Statistics(sessions: Int(sessions), events: Int(events), fileBytes: bytes))
            }
        }
    }

    /// Deletes events and sessions older than the retention period.
    public func applyRetention(_ policy: PersistencePolicy, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(policy.retentionDays) * 86_400).timeIntervalSince1970
        queue.async { [database] in
            do {
                try database.transaction {
                    try database.run("DELETE FROM events WHERE occurred_at < ?", [.real(cutoff)])
                    try database.run("DELETE FROM sessions WHERE last_event_at < ?", [.real(cutoff)])
                }
            } catch {
                PulseLog.persistence.error("Retention failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Settings › Privacy › Delete history.
    public func deleteHistory(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [database] in
            try? database.transaction {
                try database.run("DELETE FROM events")
                try database.run("DELETE FROM sessions")
            }
            try? database.execute("VACUUM;")
            completion?()
        }
    }

    public func deleteSession(_ key: SessionKey) {
        queue.async { [database] in
            try? database.transaction {
                try database.run("DELETE FROM events WHERE session_key = ?", [.text(key.rawValue)])
                try database.run("DELETE FROM sessions WHERE session_key = ?", [.text(key.rawValue)])
            }
        }
    }

    /// Waits until queued writes are done (tests and app termination).
    public func flush() {
        queue.sync {}
    }

    // MARK: Helpers

    private func decodeSession(_ json: String) -> AgentSession? {
        json.data(using: .utf8).flatMap { try? decoder.decode(AgentSession.self, from: $0) }
    }

    private func decodeEvent(_ json: String) -> AgentEvent? {
        json.data(using: .utf8).flatMap { try? decoder.decode(AgentEvent.self, from: $0) }
    }

    static func strippingPaths(_ event: AgentEvent) -> AgentEvent {
        var copy = event
        copy.projectPath = event.projectPath.map { ($0 as NSString).lastPathComponent }
        copy.origin?.projectRoot = event.origin?.projectRoot.map { ($0 as NSString).lastPathComponent }
        copy.origin?.transcriptPath = nil
        copy.origin?.hostAppPath = nil
        copy.tool?.filePaths = event.tool?.filePaths.map { ($0 as NSString).lastPathComponent } ?? []
        return copy
    }

    static func strippingPaths(_ session: AgentSession) -> AgentSession {
        var copy = session
        copy.projectPath = session.projectPath.map { ($0 as NSString).lastPathComponent }
        copy.currentDirectory = nil
        copy.origin?.projectRoot = nil
        copy.origin?.transcriptPath = nil
        copy.origin?.hostAppPath = nil
        return copy
    }
}
