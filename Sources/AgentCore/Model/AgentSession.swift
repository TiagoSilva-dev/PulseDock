import Foundation

/// What a given integration can actually observe. The UI uses this to say "we cannot see
/// this" instead of inventing it.
public struct AdapterCapabilities: Codable, Sendable, Hashable {
    public var observesTools: Bool
    public var observesPermissions: Bool
    public var observesTurnEnd: Bool
    public var observesInterrupts: Bool
    public var observesSubagents: Bool
    public var observesTasks: Bool
    public var providesProcessLiveness: Bool
    public var canAnswerApprovals: Bool
    public var canInterrupt: Bool

    public init(
        observesTools: Bool = false,
        observesPermissions: Bool = false,
        observesTurnEnd: Bool = false,
        observesInterrupts: Bool = false,
        observesSubagents: Bool = false,
        observesTasks: Bool = false,
        providesProcessLiveness: Bool = false,
        canAnswerApprovals: Bool = false,
        canInterrupt: Bool = false
    ) {
        self.observesTools = observesTools
        self.observesPermissions = observesPermissions
        self.observesTurnEnd = observesTurnEnd
        self.observesInterrupts = observesInterrupts
        self.observesSubagents = observesSubagents
        self.observesTasks = observesTasks
        self.providesProcessLiveness = providesProcessLiveness
        self.canAnswerApprovals = canAnswerApprovals
        self.canInterrupt = canInterrupt
    }

    /// True when the source only reports turn completion (Codex `notify`).
    public var isTurnEndOnly: Bool {
        observesTurnEnd && !observesTools && !observesPermissions && !observesSubagents
    }

    public func union(_ other: AdapterCapabilities) -> AdapterCapabilities {
        AdapterCapabilities(
            observesTools: observesTools || other.observesTools,
            observesPermissions: observesPermissions || other.observesPermissions,
            observesTurnEnd: observesTurnEnd || other.observesTurnEnd,
            observesInterrupts: observesInterrupts || other.observesInterrupts,
            observesSubagents: observesSubagents || other.observesSubagents,
            observesTasks: observesTasks || other.observesTasks,
            providesProcessLiveness: providesProcessLiveness || other.providesProcessLiveness,
            canAnswerApprovals: canAnswerApprovals || other.canAnswerApprovals,
            canInterrupt: canInterrupt || other.canInterrupt
        )
    }

    public static let none = AdapterCapabilities()

    public static func `for`(_ method: CollectionMethod) -> AdapterCapabilities {
        switch method {
        case .claudeHook:
            AdapterCapabilities(observesTools: true, observesPermissions: true, observesTurnEnd: true,
                                observesInterrupts: false, observesSubagents: true, observesTasks: true,
                                providesProcessLiveness: true)
        case .codexHook:
            AdapterCapabilities(observesTools: true, observesPermissions: true, observesTurnEnd: true,
                                observesInterrupts: true, observesSubagents: true, observesTasks: false,
                                providesProcessLiveness: true)
        case .codexNotify:
            AdapterCapabilities(observesTurnEnd: true)
        case .codexAppServer:
            AdapterCapabilities(observesTools: true, observesPermissions: true, observesTurnEnd: true,
                                observesInterrupts: true, observesSubagents: true, observesTasks: false,
                                providesProcessLiveness: true, canAnswerApprovals: true, canInterrupt: true)
        case .sessionRegistry:
            AdapterCapabilities(providesProcessLiveness: true)
        case .fixture:
            AdapterCapabilities(observesTools: true, observesPermissions: true, observesTurnEnd: true,
                                observesInterrupts: true, observesSubagents: true, observesTasks: true)
        case .reconciliation:
            .none
        }
    }
}

public struct TurnRecord: Codable, Sendable, Hashable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var state: TurnState
    public var confidence: Confidence
    /// Machine reason for the final state (for example "superseded_by_new_prompt").
    public var endReason: String?
    public var toolCount: Int
    public var failedToolCount: Int
    /// Slash command that started the turn, if any (name only).
    public var command: String?

    public init(id: String, startedAt: Date, state: TurnState = .running, confidence: Confidence = .confirmed, command: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.state = state
        self.confidence = confidence
        self.toolCount = 0
        self.failedToolCount = 0
        self.command = command
    }
}

public struct ToolInFlight: Codable, Sendable, Hashable {
    public var tool: ToolInfo
    public var startedAt: Date
    public var subagentID: String?
}

public struct AttentionRequest: Codable, Sendable, Hashable {
    public var info: AttentionInfo
    public var requestedAt: Date
    public var toolUseID: String?
    public var inputFingerprint: String?
    public var subagentID: String?
}

public enum SubagentStatus: String, Codable, Sendable, Hashable {
    case running
    case completed
    case unknown
}

public struct SubagentRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String?
    public var description: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var status: SubagentStatus
    public var toolCount: Int
}

public struct TaskRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var subject: String?
    public var status: TaskStatus
    public var createdAt: Date
    public var completedAt: Date?
}

public struct FailureRecord: Codable, Sendable, Hashable {
    public var info: FailureInfo
    public var at: Date
    public var toolName: String?
}

/// Everything PulseDock knows about one agent session, derived only from events.
public struct AgentSession: Codable, Sendable, Hashable, Identifiable {
    public var id: SessionKey { key }
    public var key: SessionKey
    public var title: String?
    public var projectPath: String?
    public var currentDirectory: String?
    public var lifecycle: SessionLifecycle
    /// Last state established by events (before staleness evaluation).
    public var state: SessionState
    public var stateConfidence: Confidence
    public var stateReason: String?
    public var currentTurn: TurnRecord?
    public var lastTurn: TurnRecord?
    public var turnCount: Int
    public var activity: ActivityDescriptor?
    public var toolsInFlight: [String: ToolInFlight]
    /// Everything the agent is currently waiting on the user for, oldest first.
    public var pendingAttentions: [AttentionRequest]
    /// Set when the agent finished and is waiting for the next instruction.
    public var awaitingInputSince: Date?
    public var subagents: [String: SubagentRecord]
    public var tasks: [TaskRecord]
    public var plan: PlanSnapshot?
    public var recentFailure: FailureRecord?
    /// Background work reported in flight when the last turn ended.
    public var backgroundTaskCount: Int
    public var startedAt: Date?
    public var firstSeenAt: Date
    public var lastEventAt: Date
    /// Latest evidence that the agent is alive and producing output (events or heartbeats).
    public var lastEvidenceAt: Date
    public var lastStateChangeAt: Date
    public var endedAt: Date?
    public var endReason: String?
    public var origin: SessionOrigin?
    public var capabilities: AdapterCapabilities
    public var collectionMethods: Set<CollectionMethod>
    public var eventCount: Int
    public var model: String?
    public var permissionMode: String?

    public init(key: SessionKey, firstSeenAt: Date) {
        self.key = key
        self.lifecycle = .active
        self.state = .unknown
        self.stateConfidence = .unknown
        self.turnCount = 0
        self.toolsInFlight = [:]
        self.pendingAttentions = []
        self.subagents = [:]
        self.tasks = []
        self.backgroundTaskCount = 0
        self.firstSeenAt = firstSeenAt
        self.lastEventAt = firstSeenAt
        self.lastEvidenceAt = firstSeenAt
        self.lastStateChangeAt = firstSeenAt
        self.capabilities = .none
        self.collectionMethods = []
        self.eventCount = 0
    }

    public var provider: AgentProvider { key.provider }
    public var sessionID: String { key.sessionID }
    /// Demo sessions come from declared fixtures; they are badged in the UI and never
    /// written to the history database.
    public var isDemo: Bool { key.provider == .demo || collectionMethods.contains(.fixture) }

    /// The most urgent pending request (permission before question before input).
    public var pendingAttention: AttentionRequest? {
        pendingAttentions.min { lhs, rhs in
            if lhs.info.kind.urgency != rhs.info.kind.urgency { return lhs.info.kind.urgency < rhs.info.kind.urgency }
            return lhs.requestedAt < rhs.requestedAt
        }
    }

    public var runningSubagents: [SubagentRecord] {
        subagents.values.filter { $0.status == .running }.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }
}
