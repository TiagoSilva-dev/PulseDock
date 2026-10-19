import AgentBridge
import AgentCore
import Diagnostics
import Foundation
import Observation
import Persistence

/// The app's view of every agent session. Owns the deterministic engine, persists what the
/// privacy settings allow, reconciles liveness, and publishes an aggregate for the UI.
@Observable
final class AgentStore {
    private(set) var summary: AggregateSummary = .empty
    /// Increments whenever any session changes; views use it to refresh derived values.
    private(set) var revision = 0
    private(set) var lastEventAt: [AgentProvider: Date] = [:]
    private(set) var isDemoRunning = false

    @ObservationIgnored let engine = AgentSessionEngine()
    @ObservationIgnored let projects = ProjectResolver()
    @ObservationIgnored private let persistence: PersistenceController?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var nextChangeTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTimer: Timer?
    @ObservationIgnored private var demoPlayer: DemoPlayer?
    @ObservationIgnored private var liveness: [SessionKey: Bool] = [:]
    /// Called with every accepted batch (notifications, island flashes).
    @ObservationIgnored var onEvents: ([AgentEvent]) -> Void = { _ in }
    @ObservationIgnored var onSummaryChange: (AggregateSummary) -> Void = { _ in }

    init(persistence: PersistenceController?, settings: SettingsStore) {
        self.persistence = persistence
        self.settings = settings
    }

    var text: AgentText { AgentText(privacyMode: settings.settings.privacy.privacyMode) }

    var policy: PresentationPolicy {
        let agents = settings.settings.agents
        return PresentationPolicy(staleness: StalenessPolicy(
            workingQuietLimit: agents.workingQuietLimitMinutes * 60,
            toolQuietLimit: agents.toolQuietLimitMinutes * 60
        ))
    }

    var muted: Set<SessionKey> { Set(settings.settings.agents.muted.compactMap(SessionKey.init(rawValue:))) }
    var pinned: Set<SessionKey> { Set(settings.settings.agents.pinned.compactMap(SessionKey.init(rawValue:))) }

    // MARK: Lifecycle

    /// Restores recent sessions so a restart does not forget sessions still running.
    func restore() async {
        guard let persistence else { return }
        let since = Date().addingTimeInterval(-24 * 3600)
        let sessions = await persistence.sessions(since: since)
        engine.restore(sessions.filter { $0.lifecycle == .active || ($0.endedAt.map { Date().timeIntervalSince($0) < 3600 } ?? false) })
        reconcile()
        refresh()
    }

    func start() {
        reconcileTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
        if let persistence {
            persistence.applyRetention(persistencePolicy)
        }
    }

    var persistencePolicy: PersistencePolicy {
        let privacy = settings.settings.privacy
        return PersistencePolicy(storeHistory: privacy.storeHistory, storePaths: privacy.storePaths, retentionDays: privacy.retentionDays)
    }

    // MARK: Ingest

    func ingest(_ events: [AgentEvent]) {
        guard settings.settings.agents.enabled, !events.isEmpty else { return }
        var accepted: [AgentEvent] = []
        for event in events {
            switch engine.ingest(event) {
            case .applied, .reordered:
                accepted.append(event)
                if event.collection != .reconciliation, event.collection != .sessionRegistry {
                    lastEventAt[event.provider] = max(lastEventAt[event.provider] ?? .distantPast, event.receivedAt)
                }
            case .duplicate:
                DiagnosticsRecorder.shared.increment("agents.events.duplicate")
            case let .rejected(reason):
                DiagnosticsRecorder.shared.increment("agents.events.rejected")
                DiagnosticsRecorder.shared.record(.warning, "agents", "event rejected: \(reason)")
            }
        }
        guard !accepted.isEmpty else { return }
        DiagnosticsRecorder.shared.increment("agents.events.accepted", by: accepted.count)
        let changed = Set(accepted.map(\.sessionKey))
        let sessions = changed.compactMap { engine.session($0) }
        persistence?.record(events: accepted, sessions: sessions, policy: persistencePolicy)
        refresh()
        onEvents(accepted)
    }

    // MARK: Presentation

    func processAlive(_ session: AgentSession) -> Bool? {
        liveness[session.key]
    }

    /// Recomputes the aggregate and schedules exactly one refresh for its next time-based
    /// change (end of a completion flash, a session becoming stale…).
    func refresh() {
        let now = Date()
        let sessions = Array(engine.sessions.values)
        let next = AgentPresenter.summarize(
            sessions,
            now: now,
            policy: policy,
            processAlive: { [liveness] in liveness[$0.key] },
            muted: muted,
            pinned: pinned
        )
        summary = next
        revision &+= 1
        onSummaryChange(next)
        nextChangeTask?.cancel()
        if let date = next.nextChangeAt {
            let delay = max(0.25, date.timeIntervalSince(now))
            nextChangeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func presentation(for key: SessionKey) -> SessionPresentation? {
        summary.sessions.first { $0.id == key }
            ?? engine.session(key).map {
                AgentPresenter.present($0, now: Date(), policy: policy, processAlive: liveness[key], isMuted: muted.contains(key), isPinned: pinned.contains(key))
            }
    }

    func project(for session: AgentSession) -> ProjectInfo? {
        projects.resolve(session.projectPath ?? session.currentDirectory)
    }

    // MARK: User actions

    func toggleMute(_ key: SessionKey) {
        settings.update { settings in
            if let index = settings.agents.muted.firstIndex(of: key.rawValue) {
                settings.agents.muted.remove(at: index)
            } else {
                settings.agents.muted.append(key.rawValue)
            }
        }
        refresh()
    }

    func togglePin(_ key: SessionKey) {
        settings.update { settings in
            if let index = settings.agents.pinned.firstIndex(of: key.rawValue) {
                settings.agents.pinned.remove(at: index)
            } else {
                settings.agents.pinned.append(key.rawValue)
            }
        }
        refresh()
    }

    /// Removes a finished session from the live list (history keeps it).
    func dismiss(_ key: SessionKey) {
        engine.remove(key)
        refresh()
    }

    /// Timeline: buffered in-memory events plus the persisted history of the session.
    func events(for key: SessionKey) async -> [AgentEvent] {
        let buffered = engine.bufferedEvents(for: key)
        guard let persistence, !(engine.session(key)?.isDemo ?? false) else { return buffered }
        let stored = await persistence.events(for: key)
        var byID: [String: AgentEvent] = [:]
        for event in stored + buffered { byID[event.id] = event }
        return byID.values.sorted { $0.order < $1.order }
    }

    // MARK: Reconciliation

    /// Every 30 s (only meaningful while sessions are active): process liveness, transcript
    /// activity as a heartbeat, and process-exit detection. Reads metadata only (pid, file
    /// modification time), never file contents.
    func reconcile() {
        var heartbeats: [AgentEvent] = []
        let now = Date()
        for session in engine.sessions.values where session.lifecycle == .active && !session.isDemo {
            if let pid = session.origin?.agentPID {
                liveness[session.key] = ProcessInspector.isAlive(pid: pid, start: session.origin?.agentStartTime)
            }
            if session.state == .working || session.state == .waitingUser,
               let path = session.origin?.transcriptPath,
               let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date,
               modified > session.lastEvidenceAt.addingTimeInterval(1), modified <= now.addingTimeInterval(5) {
                heartbeats.append(AgentEvent(
                    id: "heartbeat-\(session.key.rawValue)-\(Int(modified.timeIntervalSince1970))",
                    provider: session.provider,
                    sessionID: session.sessionID,
                    kind: .heartbeat,
                    receivedAt: now,
                    order: EventOrder(date: modified),
                    collection: .reconciliation,
                    confidence: .inferred,
                    sourceEvent: "transcript-activity"
                ))
            }
        }
        for event in heartbeats { engine.ingest(event) }
        let exited = engine.reconcileProcessLiveness(now: now) { [liveness] session in
            liveness[session.key]
        }
        if !exited.isEmpty {
            let sessions = Set(exited.map(\.sessionKey)).compactMap { engine.session($0) }
            persistence?.record(events: exited, sessions: sessions, policy: persistencePolicy)
            onEvents(exited)
        }
        // Forget sessions that ended long ago (still in history).
        engine.removeAll { session in
            guard session.lifecycle == .ended, let ended = session.endedAt else { return false }
            return now.timeIntervalSince(ended) > 3600
        }
        refresh()
    }

    /// Registry entries (Claude Code) give discovery and liveness for sessions that started
    /// before PulseDock or before hooks were installed.
    func applyRegistry(_ entries: [ClaudeRegistryEntry]) {
        guard settings.settings.agents.useSessionRegistry else { return }
        var events: [AgentEvent] = []
        for entry in entries {
            liveness[SessionKey(provider: .claudeCode, sessionID: entry.sessionID)] = true
            events.append(entry.event)
        }
        guard !events.isEmpty else { return }
        for event in events { engine.ingest(event) }
        refresh()
    }

    // MARK: Demo mode

    func setDemo(_ enabled: Bool) {
        if enabled {
            guard demoPlayer == nil else { return }
            let player = DemoPlayer { [weak self] events in self?.ingestDemo(events) }
            demoPlayer = player
            isDemoRunning = true
            player.start()
        } else {
            demoPlayer?.stop()
            demoPlayer = nil
            isDemoRunning = false
            engine.removeAll(where: \.isDemo)
            refresh()
        }
    }

    private func ingestDemo(_ events: [AgentEvent]) {
        if events.isEmpty { engine.removeAll(where: \.isDemo) }
        for event in events { engine.ingest(event) }
        refresh()
        onEvents(events)
    }

    func restartDemo() {
        engine.removeAll(where: \.isDemo)
        demoPlayer?.restart()
    }
}

/// Registry entry already converted to a discovery event (built off the main thread).
struct ClaudeRegistryEntry: Sendable {
    var sessionID: String
    var event: AgentEvent
}
