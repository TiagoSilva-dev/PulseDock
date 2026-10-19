import Foundation

/// Stable identity of a session across providers.
public struct SessionKey: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public var provider: AgentProvider
    public var sessionID: String

    public init(provider: AgentProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }

    public var rawValue: String { "\(provider.rawValue):\(sessionID)" }
    public var description: String { rawValue }

    public init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":"),
              let provider = AgentProvider(rawValue: String(rawValue[..<separator])) else { return nil }
        self.provider = provider
        self.sessionID = String(rawValue[rawValue.index(after: separator)...])
    }

    public static func < (lhs: SessionKey, rhs: SessionKey) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Normalised event kinds shared by every provider.
public enum AgentEventKind: String, Codable, Sendable, CaseIterable, Hashable {
    case sessionStarted = "session_started"
    case sessionEnded = "session_ended"
    /// A session seen through a discovery source (no state information).
    case sessionDiscovered = "session_discovered"
    /// A user (or scheduled) prompt started a turn.
    case promptSubmitted = "prompt_submitted"
    /// A turn started without prompt information (Codex app-server).
    case turnStarted = "turn_started"
    case toolStarted = "tool_started"
    case toolCompleted = "tool_completed"
    case toolFailed = "tool_failed"
    /// Every tool call of a parallel batch resolved.
    case toolBatchCompleted = "tool_batch_completed"
    case permissionRequested = "permission_requested"
    /// Auto mode denied a tool call.
    case permissionDenied = "permission_denied"
    /// A pending approval was answered or cleared (Codex app-server).
    case approvalResolved = "approval_resolved"
    /// The agent says it needs the user (permission prompt, MCP elicitation, …).
    case attentionNeeded = "attention_needed"
    /// The agent finished a while ago and is waiting for the next instruction.
    case idleReminder = "idle_reminder"
    /// Informational notification without state impact.
    case notification = "notification"
    case subagentStarted = "subagent_started"
    case subagentStopped = "subagent_stopped"
    case taskCreated = "task_created"
    case taskUpdated = "task_updated"
    case taskCompleted = "task_completed"
    case planUpdated = "plan_updated"
    case fileChanged = "file_changed"
    case compactionStarted = "compaction_started"
    case compactionFinished = "compaction_finished"
    /// The agent finished responding (end of turn, not end of task).
    case turnCompleted = "turn_completed"
    /// The turn ended because of an error (for example an API error).
    case turnFailed = "turn_failed"
    case turnInterrupted = "turn_interrupted"
    /// Reconciliation: the agent process is gone.
    case processExited = "process_exited"
    /// Evidence of liveness without state information.
    case heartbeat = "heartbeat"
}

/// Ordering key. Hooks run as separate processes, so arrival order is not guaranteed;
/// the helper stamps each event with wall-clock and monotonic time as early as possible.
public struct EventOrder: Codable, Sendable, Hashable, Comparable {
    public var wallMillis: Int64
    public var bootID: String?
    public var monotonicNanos: UInt64?
    /// Arrival sequence assigned by the engine; final tie-breaker.
    public var sequence: UInt64

    public init(wallMillis: Int64, bootID: String? = nil, monotonicNanos: UInt64? = nil, sequence: UInt64 = 0) {
        self.wallMillis = wallMillis
        self.bootID = bootID
        self.monotonicNanos = monotonicNanos
        self.sequence = sequence
    }

    public init(date: Date, sequence: UInt64 = 0) {
        self.init(wallMillis: Int64((date.timeIntervalSince1970 * 1000).rounded()), sequence: sequence)
    }

    public var date: Date { Date(timeIntervalSince1970: Double(wallMillis) / 1000) }

    public static func < (lhs: EventOrder, rhs: EventOrder) -> Bool {
        if let lb = lhs.bootID, let rb = rhs.bootID, lb == rb,
           let lm = lhs.monotonicNanos, let rm = rhs.monotonicNanos, lm != rm {
            return lm < rm
        }
        if lhs.wallMillis != rhs.wallMillis { return lhs.wallMillis < rhs.wallMillis }
        return lhs.sequence < rhs.sequence
    }
}

/// What the agent is observably doing. Every value maps to a concrete event field
/// (a tool name, a classified shell command, a subagent start…).
public enum ActivityKind: String, Codable, Sendable, Hashable, CaseIterable {
    case thinking
    case readingFiles = "reading_files"
    case searchingCode = "searching_code"
    case editingCode = "editing_code"
    case runningCommand = "running_command"
    case runningTests = "running_tests"
    case building
    case installingDependencies = "installing_dependencies"
    case usingGit = "using_git"
    case consultingWeb = "consulting_web"
    case usingTool = "using_tool"
    case delegating
    case planning
    case askingUser = "asking_user"
    case awaitingPlanApproval = "awaiting_plan_approval"
    case compacting
}

public struct ActivityDescriptor: Codable, Sendable, Hashable {
    public var kind: ActivityKind
    /// Short sanitized detail (a tool name, a file name, a command summary).
    public var detail: String?
    public var toolUseID: String?
    public var subagentID: String?
    public var since: Date

    public init(kind: ActivityKind, detail: String? = nil, toolUseID: String? = nil, subagentID: String? = nil, since: Date) {
        self.kind = kind
        self.detail = detail
        self.toolUseID = toolUseID
        self.subagentID = subagentID
        self.since = since
    }
}

public struct ToolInfo: Codable, Sendable, Hashable {
    public var name: String
    public var useID: String?
    public var activity: ActivityKind
    /// Sanitized one-line summary (command, file name, URL host…).
    public var summary: String?
    public var durationMillis: Int?
    public var exitCode: Int?
    /// Fingerprint of the sanitized input, used to match permission requests to tool results.
    public var inputFingerprint: String?
    public var filePaths: [String]

    public init(
        name: String,
        useID: String? = nil,
        activity: ActivityKind,
        summary: String? = nil,
        durationMillis: Int? = nil,
        exitCode: Int? = nil,
        inputFingerprint: String? = nil,
        filePaths: [String] = []
    ) {
        self.name = name
        self.useID = useID
        self.activity = activity
        self.summary = summary
        self.durationMillis = durationMillis
        self.exitCode = exitCode
        self.inputFingerprint = inputFingerprint
        self.filePaths = filePaths
    }
}

public enum AttentionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case permission
    case question
    case planApproval = "plan_approval"
    case elicitation
    case input
    case other

    /// Lower is more urgent.
    public var urgency: Int {
        switch self {
        case .permission: 0
        case .question: 1
        case .planApproval: 1
        case .elicitation: 2
        case .input: 3
        case .other: 4
        }
    }
}

public struct AttentionInfo: Codable, Sendable, Hashable {
    public var kind: AttentionKind
    public var toolName: String?
    /// Sanitized summary of what is being asked (for example the command to approve).
    public var summary: String?
    public var reason: String?
    /// Provider request identifier when the integration can answer it (Codex app-server).
    public var requestID: String?
    public var availableDecisions: [String]

    public init(kind: AttentionKind, toolName: String? = nil, summary: String? = nil, reason: String? = nil, requestID: String? = nil, availableDecisions: [String] = []) {
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.reason = reason
        self.requestID = requestID
        self.availableDecisions = availableDecisions
    }
}

public enum FailureCategory: String, Codable, Sendable, Hashable {
    case tool
    case tests
    case build
    case api
    case agent
}

public struct FailureInfo: Codable, Sendable, Hashable {
    public var category: FailureCategory
    /// Machine code (exit code, API error type).
    public var code: String?
    /// Sanitized first line (for example "Exit code 1").
    public var summary: String?

    public init(category: FailureCategory, code: String? = nil, summary: String? = nil) {
        self.category = category
        self.code = code
        self.summary = summary
    }
}

public enum TaskStatus: String, Codable, Sendable, Hashable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct TaskInfo: Codable, Sendable, Hashable {
    public var id: String
    public var subject: String?
    public var status: TaskStatus

    public init(id: String, subject: String?, status: TaskStatus) {
        self.id = id
        self.subject = subject
        self.status = status
    }
}

public struct PlanStep: Codable, Sendable, Hashable {
    public var title: String
    public var status: TaskStatus

    public init(title: String, status: TaskStatus) {
        self.title = title
        self.status = status
    }
}

public struct PlanSnapshot: Codable, Sendable, Hashable {
    public var steps: [PlanStep]
    public var source: String

    public init(steps: [PlanStep], source: String) {
        self.steps = steps
        self.source = source
    }

    public var completedCount: Int { steps.filter { $0.status == .completed }.count }
}

/// Where a session runs, captured by the hook helper from its process ancestry.
public struct SessionOrigin: Codable, Sendable, Hashable {
    public var agentPID: Int32?
    /// Process start time (seconds since 1970) used to detect PID reuse.
    public var agentStartTime: Int64?
    public var hostAppBundleID: String?
    public var hostAppPID: Int32?
    public var hostAppPath: String?
    public var tty: String?
    public var terminalProgram: String?
    public var terminalSessionID: String?
    public var tmuxPane: String?
    public var entrypoint: String?
    /// Project root reported by the agent (for example `CLAUDE_PROJECT_DIR`).
    public var projectRoot: String?
    public var transcriptPath: String?

    public init(
        agentPID: Int32? = nil,
        agentStartTime: Int64? = nil,
        hostAppBundleID: String? = nil,
        hostAppPID: Int32? = nil,
        hostAppPath: String? = nil,
        tty: String? = nil,
        terminalProgram: String? = nil,
        terminalSessionID: String? = nil,
        tmuxPane: String? = nil,
        entrypoint: String? = nil,
        projectRoot: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.agentPID = agentPID
        self.agentStartTime = agentStartTime
        self.hostAppBundleID = hostAppBundleID
        self.hostAppPID = hostAppPID
        self.hostAppPath = hostAppPath
        self.tty = tty
        self.terminalProgram = terminalProgram
        self.terminalSessionID = terminalSessionID
        self.tmuxPane = tmuxPane
        self.entrypoint = entrypoint
        self.projectRoot = projectRoot
        self.transcriptPath = transcriptPath
    }

    /// Fills missing fields from another origin (newer non-nil values win).
    public func merged(with newer: SessionOrigin) -> SessionOrigin {
        SessionOrigin(
            agentPID: newer.agentPID ?? agentPID,
            agentStartTime: newer.agentPID != nil ? newer.agentStartTime : agentStartTime,
            hostAppBundleID: newer.hostAppBundleID ?? hostAppBundleID,
            hostAppPID: newer.hostAppPID ?? hostAppPID,
            hostAppPath: newer.hostAppPath ?? hostAppPath,
            tty: newer.tty ?? tty,
            terminalProgram: newer.terminalProgram ?? terminalProgram,
            terminalSessionID: newer.terminalSessionID ?? terminalSessionID,
            tmuxPane: newer.tmuxPane ?? tmuxPane,
            entrypoint: newer.entrypoint ?? entrypoint,
            projectRoot: newer.projectRoot ?? projectRoot,
            transcriptPath: newer.transcriptPath ?? transcriptPath
        )
    }
}

/// The universal event every adapter produces.
public struct AgentEvent: Codable, Sendable, Hashable, Identifiable {
    public static let currentSchemaVersion = 1

    public var id: String
    public var schemaVersion: Int
    public var provider: AgentProvider
    public var sessionID: String
    public var turnID: String?
    /// Subagent the event happened in, when the provider reports it.
    public var subagentID: String?
    public var subagentType: String?
    public var projectPath: String?
    public var kind: AgentEventKind
    /// Timestamp from the source, when it provides one.
    public var sourceTimestamp: Date?
    public var receivedAt: Date
    public var order: EventOrder
    public var collection: CollectionMethod
    public var confidence: Confidence
    /// Raw source event name, kept for diagnostics (for example "PreToolUse").
    public var sourceEvent: String?
    public var activity: ActivityDescriptor?
    public var tool: ToolInfo?
    public var attention: AttentionInfo?
    public var failure: FailureInfo?
    public var task: TaskInfo?
    public var plan: PlanSnapshot?
    public var origin: SessionOrigin?
    /// Small sanitized key/value extras (source, reason, permission mode, model…).
    public var metadata: [String: String]

    public init(
        id: String,
        provider: AgentProvider,
        sessionID: String,
        kind: AgentEventKind,
        receivedAt: Date,
        order: EventOrder,
        collection: CollectionMethod,
        confidence: Confidence = .confirmed,
        turnID: String? = nil,
        subagentID: String? = nil,
        subagentType: String? = nil,
        projectPath: String? = nil,
        sourceTimestamp: Date? = nil,
        sourceEvent: String? = nil,
        activity: ActivityDescriptor? = nil,
        tool: ToolInfo? = nil,
        attention: AttentionInfo? = nil,
        failure: FailureInfo? = nil,
        task: TaskInfo? = nil,
        plan: PlanSnapshot? = nil,
        origin: SessionOrigin? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.schemaVersion = AgentEvent.currentSchemaVersion
        self.provider = provider
        self.sessionID = sessionID
        self.turnID = turnID
        self.subagentID = subagentID
        self.subagentType = subagentType
        self.projectPath = projectPath
        self.kind = kind
        self.sourceTimestamp = sourceTimestamp
        self.receivedAt = receivedAt
        self.order = order
        self.collection = collection
        self.confidence = confidence
        self.sourceEvent = sourceEvent
        self.activity = activity
        self.tool = tool
        self.attention = attention
        self.failure = failure
        self.task = task
        self.plan = plan
        self.origin = origin
        self.metadata = metadata
    }

    public var sessionKey: SessionKey { SessionKey(provider: provider, sessionID: sessionID) }

    /// Time used for display and staleness: the source time when known, else the order time.
    public var occurredAt: Date { sourceTimestamp ?? order.date }

    /// Content fingerprint used to drop duplicates delivered twice (for example the same
    /// handler registered in two settings files).
    public var contentFingerprint: String {
        var hasher = StableHasher()
        hasher.combine(provider.rawValue)
        hasher.combine(sessionID)
        hasher.combine(kind.rawValue)
        hasher.combine(turnID ?? "")
        hasher.combine(subagentID ?? "")
        hasher.combine(tool?.useID ?? "")
        hasher.combine(tool?.name ?? "")
        hasher.combine(tool?.inputFingerprint ?? "")
        hasher.combine(attention?.kind.rawValue ?? "")
        hasher.combine(task?.id ?? "")
        hasher.combine(metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))
        return hasher.hexDigest
    }
}

/// FNV-1a 64-bit, stable across launches (unlike `Hasher`).
public struct StableHasher: Sendable {
    private var state: UInt64 = 0xcbf2_9ce4_8422_2325

    public init() {}

    public mutating func combine(_ string: String) {
        for byte in string.utf8 {
            state ^= UInt64(byte)
            state = state &* 0x0000_0100_0000_01b3
        }
        state ^= 0xff
        state = state &* 0x0000_0100_0000_01b3
    }

    public var value: UInt64 { state }
    public var hexDigest: String { String(state, radix: 16) }

    public static func hash(_ string: String) -> String {
        var hasher = StableHasher()
        hasher.combine(string)
        return hasher.hexDigest
    }
}
