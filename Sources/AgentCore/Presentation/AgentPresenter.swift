import Foundation

/// Display priority, in the order required by the product brief: a session waiting for the
/// user must never be hidden behind sessions that are merely working.
public enum PresentationCategory: Int, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case attention = 0
    case failure = 1
    case working = 2
    case recentCompletion = 3
    case idle = 4
    case unknown = 5

    public static func < (lhs: PresentationCategory, rhs: PresentationCategory) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A session as the UI should show it right now.
public struct SessionPresentation: Sendable, Hashable, Identifiable {
    public var id: SessionKey { session.key }
    public var session: AgentSession
    public var state: SessionState
    public var confidence: Confidence
    public var reason: String?
    public var category: PresentationCategory
    public var isMuted: Bool
    public var isPinned: Bool
    /// Seconds without evidence, filled when it explains a stale or unknown state.
    public var quietFor: TimeInterval?
    /// A tool failure that happened moments ago in a still-working session.
    public var transientFailure: FailureRecord?
}

public struct AggregateSummary: Sendable, Hashable {
    public enum IslandMode: Sendable, Hashable {
        /// No live sessions.
        case empty
        /// Live sessions, nothing noteworthy right now.
        case compact
        case activity(SessionKey)
        case attention(SessionKey)
        case failure(SessionKey)
        case completionFlash(SessionKey)
    }

    public var sessions: [SessionPresentation]
    public var primary: SessionPresentation?
    public var mode: IslandMode
    public var counts: [PresentationCategory: Int]
    public var providers: [AgentProvider]
    /// Earliest moment at which the summary changes by itself (end of a flash, a session
    /// becoming stale…), so the UI can schedule exactly one refresh instead of polling.
    public var nextChangeAt: Date?

    public var attentionCount: Int { counts[.attention] ?? 0 }
    public var workingCount: Int { counts[.working] ?? 0 }
    public var liveCount: Int { sessions.count }

    public static let empty = AggregateSummary(sessions: [], primary: nil, mode: .empty, counts: [:], providers: [], nextChangeAt: nil)
}

public struct PresentationPolicy: Sendable, Hashable {
    public var staleness: StalenessPolicy
    /// A completed turn counts as "recent" for this long.
    public var recentCompletionWindow: TimeInterval
    /// A failed turn keeps failure priority for this long.
    public var failureWindow: TimeInterval
    /// Duration of the temporary "turn finished" confirmation in the island.
    public var completionFlashDuration: TimeInterval
    /// Duration of the temporary highlight after a tool failure inside a working turn.
    public var transientFailureDuration: TimeInterval

    public init(
        staleness: StalenessPolicy = .standard,
        recentCompletionWindow: TimeInterval = 5 * 60,
        failureWindow: TimeInterval = 10 * 60,
        completionFlashDuration: TimeInterval = 4.5,
        transientFailureDuration: TimeInterval = 6
    ) {
        self.staleness = staleness
        self.recentCompletionWindow = recentCompletionWindow
        self.failureWindow = failureWindow
        self.completionFlashDuration = completionFlashDuration
        self.transientFailureDuration = transientFailureDuration
    }

    public static let standard = PresentationPolicy()
}

public enum AgentPresenter {
    public static func present(
        _ session: AgentSession,
        now: Date,
        policy: PresentationPolicy,
        processAlive: Bool?,
        isMuted: Bool = false,
        isPinned: Bool = false
    ) -> SessionPresentation {
        let evaluation = policy.staleness.evaluate(session, now: now, processAlive: processAlive)
        var category: PresentationCategory
        switch evaluation.state {
        case .waitingUser, .waitingExternal:
            category = .attention
        case .failed:
            category = now.timeIntervalSince(session.lastStateChangeAt) < policy.failureWindow ? .failure : .idle
        case .working:
            category = .working
        case .completed:
            category = now.timeIntervalSince(session.lastStateChangeAt) < policy.recentCompletionWindow ? .recentCompletion : .idle
        case .interrupted, .idle:
            category = .idle
        case .stale, .unknown, .disconnected:
            category = .unknown
        }
        if session.lifecycle == .ended {
            category = max(category, .recentCompletion)
        }
        // Muted sessions keep their real category (the card still shows them waiting);
        // `priorityOrder` is what keeps them from taking over the island.
        var transient: FailureRecord?
        if evaluation.state == .working, let failure = session.recentFailure,
           now.timeIntervalSince(failure.at) < policy.transientFailureDuration {
            transient = failure
        }
        return SessionPresentation(
            session: session,
            state: evaluation.state,
            confidence: evaluation.confidence,
            reason: evaluation.reason,
            category: category,
            isMuted: isMuted,
            isPinned: isPinned,
            quietFor: evaluation.quietFor,
            transientFailure: transient
        )
    }

    /// Builds the aggregate shown by the Agent Pulse island and the Agent Card.
    public static func summarize(
        _ sessions: [AgentSession],
        now: Date,
        policy: PresentationPolicy = .standard,
        processAlive: (AgentSession) -> Bool? = { _ in nil },
        muted: Set<SessionKey> = [],
        pinned: Set<SessionKey> = [],
        includeEnded: Bool = true
    ) -> AggregateSummary {
        let visible = sessions.filter { session in
            guard session.lifecycle == .ended else { return true }
            guard includeEnded, let ended = session.endedAt else { return false }
            return now.timeIntervalSince(ended) < policy.staleness.endedVisibility
        }
        guard !visible.isEmpty else { return .empty }

        let presentations = visible.map {
            present($0, now: now, policy: policy, processAlive: processAlive($0), isMuted: muted.contains($0.key), isPinned: pinned.contains($0.key))
        }
        let sorted = presentations.sorted(by: displayOrder)

        var counts: [PresentationCategory: Int] = [:]
        for presentation in presentations { counts[presentation.category, default: 0] += 1 }

        let ranked = presentations.sorted(by: priorityOrder)
        let primary = ranked.first

        // Completion flash: a turn that finished moments ago, when nothing is more urgent.
        let flash = presentations
            .filter { $0.state == .completed && !$0.isMuted && now.timeIntervalSince($0.session.lastStateChangeAt) < policy.completionFlashDuration }
            .max { $0.session.lastStateChangeAt < $1.session.lastStateChangeAt }
        let failureFlash = presentations
            .filter { $0.transientFailure != nil && !$0.isMuted }
            .max { ($0.transientFailure?.at ?? .distantPast) < ($1.transientFailure?.at ?? .distantPast) }

        let mode: AggregateSummary.IslandMode
        if let primary, primary.category == .attention, !primary.isMuted {
            mode = .attention(primary.id)
        } else if let primary, primary.category == .failure, !primary.isMuted {
            mode = .failure(primary.id)
        } else if let failureFlash {
            mode = .failure(failureFlash.id)
        } else if let flash {
            mode = .completionFlash(flash.id)
        } else if let primary, primary.category == .working {
            mode = .activity(primary.id)
        } else {
            mode = .compact
        }

        var providers: [AgentProvider] = []
        for presentation in ranked where !providers.contains(presentation.session.provider) {
            providers.append(presentation.session.provider)
        }

        return AggregateSummary(
            sessions: sorted,
            primary: primary,
            mode: mode,
            counts: counts,
            providers: providers,
            nextChangeAt: nextChange(presentations, now: now, policy: policy)
        )
    }

    /// Island priority: category, then the oldest pending request first (it has waited the
    /// longest), then the most recent activity.
    static func priorityOrder(_ lhs: SessionPresentation, _ rhs: SessionPresentation) -> Bool {
        let lhsCategory = lhs.isMuted ? max(lhs.category, .working) : lhs.category
        let rhsCategory = rhs.isMuted ? max(rhs.category, .working) : rhs.category
        if lhsCategory != rhsCategory { return lhsCategory < rhsCategory }
        if lhsCategory == .attention {
            let lhsAt = lhs.session.pendingAttention?.requestedAt ?? lhs.session.lastStateChangeAt
            let rhsAt = rhs.session.pendingAttention?.requestedAt ?? rhs.session.lastStateChangeAt
            if lhsAt != rhsAt { return lhsAt < rhsAt }
        }
        if lhs.session.lastEventAt != rhs.session.lastEventAt { return lhs.session.lastEventAt > rhs.session.lastEventAt }
        return lhs.session.key < rhs.session.key
    }

    /// Card order: pinned sessions first, then priority.
    static func displayOrder(_ lhs: SessionPresentation, _ rhs: SessionPresentation) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return priorityOrder(lhs, rhs)
    }

    private static func nextChange(_ presentations: [SessionPresentation], now: Date, policy: PresentationPolicy) -> Date? {
        var candidates: [Date] = []
        for presentation in presentations {
            let session = presentation.session
            switch presentation.state {
            case .completed:
                candidates.append(session.lastStateChangeAt.addingTimeInterval(policy.completionFlashDuration))
                candidates.append(session.lastStateChangeAt.addingTimeInterval(policy.recentCompletionWindow))
            case .failed:
                candidates.append(session.lastStateChangeAt.addingTimeInterval(policy.failureWindow))
            case .working:
                let limit = session.toolsInFlight.isEmpty ? policy.staleness.workingQuietLimit : policy.staleness.toolQuietLimit
                candidates.append(session.lastEvidenceAt.addingTimeInterval(limit + 1))
                if let failure = presentation.transientFailure {
                    candidates.append(failure.at.addingTimeInterval(policy.transientFailureDuration))
                }
            default:
                break
            }
            if session.lifecycle == .ended, let ended = session.endedAt {
                candidates.append(ended.addingTimeInterval(policy.staleness.endedVisibility))
            }
        }
        return candidates.filter { $0 > now }.min()
    }
}

/// All pending requests across sessions, most urgent first. Drives grouped notifications.
public enum AttentionQueue {
    public struct Item: Sendable, Hashable, Identifiable {
        public var id: String { "\(session.rawValue)#\(request.requestedAt.timeIntervalSince1970)#\(request.info.kind.rawValue)" }
        public var session: SessionKey
        public var request: AttentionRequest
    }

    public static func items(from sessions: [AgentSession], muted: Set<SessionKey> = []) -> [Item] {
        sessions
            .filter { $0.lifecycle == .active && !muted.contains($0.key) }
            .flatMap { session in session.pendingAttentions.map { Item(session: session.key, request: $0) } }
            .sorted { lhs, rhs in
                if lhs.request.info.kind.urgency != rhs.request.info.kind.urgency {
                    return lhs.request.info.kind.urgency < rhs.request.info.kind.urgency
                }
                return lhs.request.requestedAt < rhs.request.requestedAt
            }
    }
}

/// Evidence-based progress: a percentage only when there is a verifiable total.
public enum ProgressInfo: Sendable, Hashable {
    case none
    case indeterminate
    case determinate(completed: Int, total: Int, source: String)

    public var fraction: Double? {
        if case let .determinate(completed, total, _) = self, total > 0 { return Double(completed) / Double(total) }
        return nil
    }
}

public enum ProgressEvaluator {
    public static func progress(for session: AgentSession, effectiveState: SessionState) -> ProgressInfo {
        if !session.tasks.isEmpty {
            let completed = session.tasks.filter { $0.status == .completed }.count
            return .determinate(completed: completed, total: session.tasks.count, source: "tasks")
        }
        if let plan = session.plan, !plan.steps.isEmpty {
            return .determinate(completed: plan.completedCount, total: plan.steps.count, source: plan.source)
        }
        return effectiveState == .working ? .indeterminate : .none
    }
}
