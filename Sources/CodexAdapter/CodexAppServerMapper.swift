import AdapterSupport
import AgentBridge
import AgentCore
import Foundation

/// Maps Codex app-server JSON-RPC traffic (Managed Mode) to `AgentEvent`s.
///
/// Method and field names follow developers.openai.com/codex/app-server. Content fields
/// (agent messages, command output, diffs, reasoning) are never copied: only identifiers,
/// statuses, sanitized command summaries and file paths.
public struct CodexAppServerMapper: Sendable {
    /// thread id → session id (`thread.sessionId`, which equals the root thread id).
    private(set) var sessions: [String: String] = [:]
    /// item id → tool description, so completions and approvals can refer back to it.
    private(set) var items: [String: ToolInfo] = [:]
    private(set) var turnFailures: [String: FailureInfo] = [:]
    private var lastThreadID: String?
    private var sequence: UInt64 = 0
    private let bootID = ProcessInspector.bootSessionID

    public init() {}

    public mutating func register(threadID: String, sessionID: String?) {
        sessions[threadID] = sessionID ?? threadID
        lastThreadID = threadID
    }

    // MARK: Notifications

    public mutating func events(forNotification method: String, params: [String: Any], now: Date = Date()) -> [AgentEvent] {
        let threadID = (params["threadId"] as? String) ?? lastThreadID
        switch method {
        case "thread/started":
            guard let thread = params["thread"] as? [String: Any], let id = thread["id"] as? String else { return [] }
            register(threadID: id, sessionID: thread["sessionId"] as? String)
            return [make(.sessionStarted, threadID: id, now: now, metadata: ["source": "app_server"])]

        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let turnID = turn["id"] as? String else { return [] }
            return [make(.turnStarted, threadID: threadID, turnID: turnID, now: now)]

        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any] else { return [] }
            return itemEvents(item: item, completed: method == "item/completed", threadID: threadID, turnID: params["turnId"] as? String, now: now)

        case "turn/plan/updated":
            guard let plan = params["plan"] as? [[String: Any]] else { return [] }
            let steps = plan.compactMap { step -> PlanStep? in
                guard let title = step["step"] as? String else { return nil }
                return PlanStep(title: SecretRedactor.clean(title, maxLength: 80), status: ToolInfoBuilder.taskStatus(step["status"] as? String))
            }
            return [make(.planUpdated, threadID: threadID, turnID: params["turnId"] as? String, now: now, plan: PlanSnapshot(steps: steps, source: "plan"))]

        case "error":
            if let error = params["error"] as? [String: Any] {
                let code = (error["codexErrorInfo"] as? String) ?? ((error["codexErrorInfo"] as? [String: Any])?.keys.first) ?? "error"
                let summary = (error["message"] as? String).map { SecretRedactor.firstLine($0, maxLength: 160) }
                if let turnID = params["turnId"] as? String {
                    turnFailures[turnID] = FailureInfo(category: .agent, code: code, summary: summary)
                }
            }
            return []

        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any], let turnID = turn["id"] as? String else { return [] }
            switch turn["status"] as? String {
            case "completed":
                return [make(.turnCompleted, threadID: threadID, turnID: turnID, now: now)]
            case "interrupted":
                return [make(.turnInterrupted, threadID: threadID, turnID: turnID, now: now)]
            case "failed":
                var failure = turnFailures.removeValue(forKey: turnID) ?? FailureInfo(category: .agent, code: "failed")
                if let error = turn["error"] as? [String: Any], let message = error["message"] as? String {
                    failure.summary = SecretRedactor.firstLine(message, maxLength: 160)
                }
                return [make(.turnFailed, threadID: threadID, turnID: turnID, now: now, failure: failure)]
            default:
                return []
            }

        case "serverRequest/resolved":
            guard let requestID = params["requestId"].map(Self.requestKey) else { return [] }
            return [make(.approvalResolved, threadID: threadID, now: now, attention: AttentionInfo(kind: .permission, requestID: requestID))]

        case "thread/closed":
            return [make(.sessionEnded, threadID: threadID, now: now, metadata: ["reason": "thread_closed"])]

        case "thread/status/changed", "turn/diff/updated", "thread/tokenUsage/updated":
            return [make(.heartbeat, threadID: threadID, now: now)]

        default:
            return []
        }
    }

    private mutating func itemEvents(item: [String: Any], completed: Bool, threadID: String?, turnID: String?, now: Date) -> [AgentEvent] {
        guard let type = item["type"] as? String, let itemID = item["id"] as? String else { return [] }
        let status = item["status"] as? String
        var tool: ToolInfo?
        switch type {
        case "commandExecution":
            let command = (item["command"] as? String) ?? ((item["command"] as? [String]).map { $0.joined(separator: " ") }) ?? ""
            let clean = SecretRedactor.clean(command, maxLength: 240)
            tool = ToolInfo(
                name: "Bash",
                useID: itemID,
                activity: CommandClassifier.activity(for: clean),
                summary: CommandClassifier.summary(for: clean),
                durationMillis: item["durationMs"] as? Int,
                exitCode: item["exitCode"] as? Int,
                inputFingerprint: StableHasher.hash("Bash|" + clean)
            )
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            tool = ToolInfo(
                name: "apply_patch",
                useID: itemID,
                activity: .editingCode,
                summary: paths.first.map { (($0 as NSString).lastPathComponent) + (paths.count > 1 ? " +\(paths.count - 1)" : "") },
                filePaths: Array(paths.prefix(40))
            )
        case "mcpToolCall":
            let name = "mcp__\(item["server"] as? String ?? "server")__\(item["tool"] as? String ?? "tool")"
            tool = ToolInfo(name: name, useID: itemID, activity: .usingTool, summary: ToolClassifier.displayName(toolName: name))
        case "webSearch":
            let query = (item["query"] as? String).map { SecretRedactor.clean($0, maxLength: 80) }
            tool = ToolInfo(name: "web_search", useID: itemID, activity: .consultingWeb, summary: query)
        case "collabToolCall":
            tool = ToolInfo(name: "spawn_agent", useID: itemID, activity: .delegating, summary: item["tool"] as? String)
        case "contextCompaction":
            return [make(completed ? .compactionFinished : .compactionStarted, threadID: threadID, turnID: turnID, now: now)]
        default:
            // agentMessage, reasoning, plan, userMessage…: evidence of progress, no content kept.
            return [make(.heartbeat, threadID: threadID, turnID: turnID, now: now)]
        }
        guard var tool else { return [] }
        if !completed {
            items[itemID] = tool
            return [make(.toolStarted, threadID: threadID, turnID: turnID, now: now, tool: tool)]
        }
        if let started = items.removeValue(forKey: itemID) {
            tool.inputFingerprint = tool.inputFingerprint ?? started.inputFingerprint
        }
        let failed = status == "failed" || status == "declined" || (tool.exitCode.map { $0 != 0 } ?? false)
        if failed {
            let code = status == "declined" ? "declined" : (tool.exitCode.map(String.init) ?? "failed")
            let failure = FailureInfo(category: ToolInfoBuilder.failureCategory(for: tool.activity), code: code,
                                      summary: tool.exitCode.map { "Exit code \($0)" } ?? status)
            return [make(.toolFailed, threadID: threadID, turnID: turnID, now: now, tool: tool, failure: failure)]
        }
        return [make(.toolCompleted, threadID: threadID, turnID: turnID, now: now, tool: tool)]
    }

    // MARK: Server requests (approvals)

    public static let supportedApprovalMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
    ]

    public mutating func events(forServerRequest method: String, requestID: String, params: [String: Any], now: Date = Date()) -> [AgentEvent] {
        let threadID = (params["threadId"] as? String) ?? lastThreadID
        let turnID = params["turnId"] as? String
        let itemID = params["itemId"] as? String
        let reason = (params["reason"] as? String).map { SecretRedactor.clean($0, maxLength: 200) }
        let decisions = (params["availableDecisions"] as? [Any])?.compactMap { $0 as? String }
        switch method {
        case "item/commandExecution/requestApproval":
            let command = (params["command"] as? String).map { SecretRedactor.clean($0, maxLength: 240) }
            var tool = itemID.flatMap { items[$0] } ?? ToolInfo(name: "Bash", activity: .runningCommand)
            if let command { tool.summary = command }
            let attention = AttentionInfo(kind: .permission, toolName: "Bash", summary: command ?? tool.summary, reason: reason,
                                          requestID: requestID, availableDecisions: decisions ?? ["accept", "acceptForSession", "decline", "cancel"])
            var metadata: [String: String] = [:]
            if let cwd = params["cwd"] as? String { metadata["cwd"] = cwd }
            if params["networkApprovalContext"] != nil { metadata["network"] = "true" }
            return [make(.permissionRequested, threadID: threadID, turnID: turnID, now: now, tool: tool, attention: attention, metadata: metadata)]
        case "item/fileChange/requestApproval":
            let tool = itemID.flatMap { items[$0] } ?? ToolInfo(name: "apply_patch", activity: .editingCode)
            let attention = AttentionInfo(kind: .permission, toolName: "apply_patch", summary: tool.summary, reason: reason,
                                          requestID: requestID, availableDecisions: decisions ?? ["accept", "acceptForSession", "decline", "cancel"])
            return [make(.permissionRequested, threadID: threadID, turnID: turnID, now: now, tool: tool, attention: attention)]
        case "item/tool/requestUserInput", "tool/requestUserInput":
            return [make(.attentionNeeded, threadID: threadID, turnID: turnID, now: now,
                         attention: AttentionInfo(kind: .question, summary: reason, requestID: requestID, availableDecisions: ["cancel"]))]
        case "item/permissions/requestApproval":
            return [make(.permissionRequested, threadID: threadID, turnID: turnID, now: now,
                         attention: AttentionInfo(kind: .permission, summary: reason, requestID: requestID, availableDecisions: ["decline"]))]
        case "mcpServer/elicitation/request":
            return [make(.attentionNeeded, threadID: threadID, turnID: turnID, now: now,
                         attention: AttentionInfo(kind: .elicitation, summary: (params["message"] as? String).map { SecretRedactor.clean($0, maxLength: 200) },
                                                  requestID: requestID, availableDecisions: ["decline", "cancel"]))]
        default:
            return []
        }
    }

    // MARK: Helpers

    static func requestKey(_ id: Any) -> String {
        if let number = id as? NSNumber { return number.stringValue }
        if let string = id as? String { return string }
        return String(describing: id)
    }

    private mutating func make(
        _ kind: AgentEventKind,
        threadID: String?,
        turnID: String? = nil,
        now: Date,
        tool: ToolInfo? = nil,
        attention: AttentionInfo? = nil,
        failure: FailureInfo? = nil,
        plan: PlanSnapshot? = nil,
        metadata: [String: String] = [:]
    ) -> AgentEvent {
        sequence += 1
        let thread = threadID ?? "unknown-thread"
        let session = sessions[thread] ?? thread
        return AgentEvent(
            id: "codex-app-\(thread)-\(sequence)-\(kind.rawValue)",
            provider: .codex,
            sessionID: session,
            kind: kind,
            receivedAt: now,
            order: EventOrder(wallMillis: Int64((now.timeIntervalSince1970 * 1000).rounded()), bootID: bootID,
                              monotonicNanos: ProcessInspector.monotonicNanos),
            collection: .codexAppServer,
            turnID: turnID,
            sourceEvent: kind.rawValue,
            tool: tool,
            attention: attention,
            failure: failure,
            plan: plan,
            metadata: metadata
        )
    }
}
