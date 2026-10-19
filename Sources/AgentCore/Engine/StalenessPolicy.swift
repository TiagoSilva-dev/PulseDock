import Foundation

/// Decides when the last known state is too old to be shown as current.
///
/// Hooks do not send heartbeats, and a model can think for minutes without emitting any
/// event, so silence alone never means "idle". The policy only downgrades to `stale`
/// after a configurable quiet period and never upgrades anything to success.
public struct StalenessPolicy: Codable, Sendable, Hashable {
    /// Quiet period for `working` with no tool in flight (the model is generating).
    public var workingQuietLimit: TimeInterval
    /// Quiet period for `working` while a tool is running (builds and test suites are long).
    public var toolQuietLimit: TimeInterval
    /// Quiet period for `waiting_user` when process liveness cannot be checked.
    public var waitingQuietLimitWithoutLiveness: TimeInterval
    /// How long ended sessions stay in the live list before moving to history only.
    public var endedVisibility: TimeInterval

    public init(
        workingQuietLimit: TimeInterval = 10 * 60,
        toolQuietLimit: TimeInterval = 45 * 60,
        waitingQuietLimitWithoutLiveness: TimeInterval = 3 * 60 * 60,
        endedVisibility: TimeInterval = 15 * 60
    ) {
        self.workingQuietLimit = workingQuietLimit
        self.toolQuietLimit = toolQuietLimit
        self.waitingQuietLimitWithoutLiveness = waitingQuietLimitWithoutLiveness
        self.endedVisibility = endedVisibility
    }

    public static let standard = StalenessPolicy()

    public struct Evaluation: Sendable, Hashable {
        public var state: SessionState
        public var confidence: Confidence
        public var reason: String?
        /// Seconds since the last evidence, when it matters for the label.
        public var quietFor: TimeInterval?
    }

    /// - Parameter processAlive: `true`/`false` when liveness was checked, `nil` when unknown.
    public func evaluate(_ session: AgentSession, now: Date, processAlive: Bool?) -> Evaluation {
        let stored = Evaluation(state: session.state, confidence: session.stateConfidence, reason: session.stateReason, quietFor: nil)
        guard session.lifecycle == .active else { return stored }
        let quiet = max(0, now.timeIntervalSince(session.lastEvidenceAt))
        switch session.state {
        case .working:
            if processAlive == false {
                return Evaluation(state: .stale, confidence: .inferred, reason: "process_not_running", quietFor: quiet)
            }
            let limit = session.toolsInFlight.isEmpty ? workingQuietLimit : toolQuietLimit
            if quiet > limit {
                return Evaluation(state: .stale, confidence: .inferred, reason: "no_events", quietFor: quiet)
            }
            return stored
        case .waitingUser, .waitingExternal:
            if processAlive == true { return stored }
            if processAlive == false || quiet > waitingQuietLimitWithoutLiveness {
                return Evaluation(state: .stale, confidence: .inferred, reason: "no_events", quietFor: quiet)
            }
            return stored
        case .unknown, .stale:
            return Evaluation(state: session.state, confidence: .unknown, reason: session.stateReason, quietFor: quiet)
        case .idle, .completed, .failed, .interrupted, .disconnected:
            return stored
        }
    }
}
