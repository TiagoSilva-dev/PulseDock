import Foundation

/// AI coding agent providers PulseDock understands.
public enum AgentProvider: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode = "claude_code"
    case codex = "codex"
    /// Deterministic fixtures shown only in Demo mode, never persisted as real history.
    case demo = "demo"

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .demo: "Demo"
        }
    }

    public var shortName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .demo: "Demo"
        }
    }
}

/// Normalised session state (the official state machine of the product brief).
public enum SessionState: String, Codable, Sendable, CaseIterable, Hashable {
    /// Integration not configured or unavailable.
    case disconnected
    /// Session known, no current activity confirmed.
    case idle
    /// Work in progress confirmed by events.
    case working
    /// Waiting for an action or authorisation from the user.
    case waitingUser = "waiting_user"
    /// Waiting for an external resource, when observable.
    case waitingExternal = "waiting_external"
    /// The turn (not necessarily the task) finished.
    case completed
    /// Failure confirmed by an event.
    case failed
    /// Activity interrupted.
    case interrupted
    /// The last information is too old to represent the current state.
    case stale
    /// Not enough events for a reliable conclusion.
    case unknown

    /// Whether this state means the agent is not doing anything right now.
    public var isQuiescent: Bool {
        switch self {
        case .idle, .completed, .failed, .interrupted, .disconnected: true
        case .working, .waitingUser, .waitingExternal, .stale, .unknown: false
        }
    }
}

/// State of a single turn (one user request and the agent work that follows).
public enum TurnState: String, Codable, Sendable, Hashable {
    case running
    case completed
    case failed
    case interrupted
}

public enum SessionLifecycle: String, Codable, Sendable, Hashable {
    case active
    case ended
}

/// How reliable a state or event is.
public enum Confidence: String, Codable, Sendable, Hashable, Comparable {
    /// Directly reported by the agent through an official mechanism.
    case confirmed
    /// Derived deterministically from other confirmed facts (for example, a new prompt
    /// arrived while the previous turn never reported completion).
    case inferred
    /// No reliable basis.
    case unknown

    private var rank: Int {
        switch self {
        case .confirmed: 2
        case .inferred: 1
        case .unknown: 0
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
}

/// Where an event came from.
public enum CollectionMethod: String, Codable, Sendable, Hashable {
    case claudeHook = "claude_hook"
    case codexHook = "codex_hook"
    case codexNotify = "codex_notify"
    case codexAppServer = "codex_app_server"
    /// Claude Code's local session registry (discovery and liveness only).
    case sessionRegistry = "session_registry"
    /// PulseDock's own reconciliation (process exit, staleness).
    case reconciliation = "reconciliation"
    case fixture = "fixture"
}
