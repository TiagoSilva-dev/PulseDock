import Foundation

/// Agent Heartbeat: an electrocardiogram of what agents observably did in the last minutes,
/// plus the outcome of the test commands they ran ("Test Radar").
///
/// Every beat comes from a concrete event (a tool call, a permission request, a failure, an
/// end of turn). Quiet stretches stay flat: the absence of events is never drawn as activity.
public enum AgentHeartbeat {
    public enum BeatKind: Int, Sendable, Hashable, Comparable, CaseIterable {
        case activity = 0
        case completion
        case failure
        case attention

        public static func < (lhs: BeatKind, rhs: BeatKind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Beat: Sendable, Hashable {
        public var session: SessionKey
        public var date: Date
        public var kind: BeatKind
        /// Simulated (demo fixtures); the UI labels it DEMO.
        public var isDemo: Bool

        public init(session: SessionKey, date: Date, kind: BeatKind, isDemo: Bool = false) {
            self.session = session
            self.date = date
            self.kind = kind
            self.isDemo = isDemo
        }
    }

    /// One row of the strip: per time bucket, how many beats and the most important kind.
    public struct Lane: Sendable, Hashable, Identifiable {
        public var id: SessionKey { session }
        public var session: SessionKey
        public var counts: [Int]
        public var kinds: [BeatKind?]
        public var lastBeat: Date?
        public var isDemo = false

        public var total: Int { counts.reduce(0, +) }
    }

    /// The beat an event produces, if any. Discovery, heartbeats and reconciliation are not
    /// agent activity and produce none.
    public static func beat(for event: AgentEvent) -> Beat? {
        let kind: BeatKind
        switch event.kind {
        case .toolStarted, .toolCompleted, .promptSubmitted, .turnStarted, .subagentStarted, .subagentStopped,
             .fileChanged, .taskCreated, .taskUpdated, .taskCompleted, .planUpdated, .compactionStarted:
            kind = .activity
        case .toolFailed, .turnFailed, .permissionDenied:
            kind = .failure
        case .permissionRequested, .attentionNeeded:
            kind = .attention
        case .turnCompleted:
            kind = .completion
        default:
            return nil
        }
        return Beat(session: SessionKey(provider: event.provider, sessionID: event.sessionID), date: event.order.date, kind: kind,
                    isDemo: event.provider == .demo || event.collection == .fixture)
    }

    /// Folds beats into `bucketCount` equal buckets ending at `now`. Lanes are ordered by
    /// their most recent beat; lanes with no beat inside the window are dropped.
    public static func lanes(_ beats: [Beat], now: Date, window: TimeInterval, bucketCount: Int, maxLanes: Int = 4) -> [Lane] {
        guard bucketCount > 0, window > 0 else { return [] }
        let start = now.addingTimeInterval(-window)
        let width = window / Double(bucketCount)
        var lanes: [SessionKey: Lane] = [:]
        for beat in beats where beat.date >= start && beat.date <= now {
            let index = min(bucketCount - 1, max(0, Int(beat.date.timeIntervalSince(start) / width)))
            var lane = lanes[beat.session] ?? Lane(session: beat.session, counts: Array(repeating: 0, count: bucketCount),
                                                  kinds: Array(repeating: nil, count: bucketCount), lastBeat: nil)
            lane.counts[index] += 1
            lane.kinds[index] = max(lane.kinds[index] ?? beat.kind, beat.kind)
            lane.lastBeat = max(lane.lastBeat ?? beat.date, beat.date)
            lane.isDemo = lane.isDemo || beat.isDemo
            lanes[beat.session] = lane
        }
        return lanes.values
            .sorted { ($0.lastBeat ?? .distantPast) > ($1.lastBeat ?? .distantPast) }
            .prefix(maxLanes)
            .map { $0 }
    }

    /// Beats per minute over the whole window (all sessions), rounded.
    public static func beatsPerMinute(_ beats: [Beat], now: Date, window: TimeInterval) -> Int {
        guard window > 0 else { return 0 }
        let start = now.addingTimeInterval(-window)
        let count = beats.filter { $0.date >= start && $0.date <= now }.count
        return Int((Double(count) / (window / 60)).rounded())
    }

    // MARK: Test Radar

    public struct TestRun: Sendable, Hashable, Identifiable {
        public enum Outcome: Sendable, Hashable {
            /// The test command exited with status 0.
            case passed
            /// The command finished without error, but the integration reported no exit code.
            case finishedWithoutError
            /// The command failed (non-zero exit code when known).
            case failed(exitCode: Int?)
        }

        public var id: String
        public var session: SessionKey
        public var projectPath: String?
        public var command: String?
        public var date: Date
        public var outcome: Outcome
        public var durationMillis: Int?
        public var isDemo = false
    }

    /// A finished test command, from the same classification that labels "Running tests".
    public static func testRun(from event: AgentEvent) -> TestRun? {
        guard let tool = event.tool, tool.activity == .runningTests else { return nil }
        let outcome: TestRun.Outcome
        switch event.kind {
        case .toolCompleted:
            switch tool.exitCode {
            case 0?: outcome = .passed
            case let code?: outcome = .failed(exitCode: code)
            case nil: outcome = .finishedWithoutError
            }
        case .toolFailed:
            outcome = .failed(exitCode: tool.exitCode ?? event.failure?.code.flatMap { Int($0) })
        default:
            return nil
        }
        return TestRun(id: event.id, session: SessionKey(provider: event.provider, sessionID: event.sessionID),
                       projectPath: event.projectPath, command: tool.summary, date: event.order.date,
                       outcome: outcome, durationMillis: tool.durationMillis,
                       isDemo: event.provider == .demo || event.collection == .fixture)
    }

    /// The latest run per project (or per session when the project is unknown), newest first.
    public static func latestRuns(_ runs: [TestRun], limit: Int = 6) -> [TestRun] {
        var latest: [String: TestRun] = [:]
        for run in runs {
            let key = run.projectPath ?? run.session.rawValue
            if let existing = latest[key], existing.date >= run.date { continue }
            latest[key] = run
        }
        return latest.values.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }
}
