import AdapterSupport
import AgentBridge
import AgentCore
import Foundation

/// Converts sanitized Claude Code hook envelopes into universal `AgentEvent`s.
///
/// Field names follow the hooks reference for Claude Code 2.1.x
/// (code.claude.com/docs/en/hooks). `prompt_id` identifies the turn: it is assigned per user
/// prompt and carried by every hook that fires while that prompt is processed.
public enum ClaudeCodeNormalizer {
    public static let supportedEvents: [String] = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PostToolBatch", "PermissionRequest", "PermissionDenied", "Notification", "SubagentStart", "SubagentStop",
        "TaskCreated", "TaskCompleted", "Stop", "StopFailure", "PreCompact", "PostCompact",
    ]

    public static func normalize(_ envelope: BridgeEnvelope, receivedAt: Date = Date()) -> [AgentEvent] {
        guard envelope.source == .claudeCode, envelope.kind == .hook else { return [] }
        let payload = envelope.payload
        guard let sessionID = payload["session_id"]?.stringValue, !sessionID.isEmpty else { return [] }

        let eventName = envelope.event
        let isSubagentLifecycle = eventName == "SubagentStart" || eventName == "SubagentStop"
        // `agent_id` marks events that happen inside a subagent (or in-process teammate).
        let subagentID = payload["agent_id"]?.stringValue
        let subagentType = payload["agent_type"]?.stringValue

        var metadata = EnvelopeContext.metadata(from: payload, keys: [
            "permission_mode", "model", "source", "reason", "session_title", "notification_type", "trigger", "effort",
        ])
        if let command = payload["command"]?.stringValue { metadata["command"] = command }

        func event(_ kind: AgentEventKind, suffix: String? = nil, tool: ToolInfo? = nil, attention: AttentionInfo? = nil,
                   failure: FailureInfo? = nil, task: TaskInfo? = nil, plan: PlanSnapshot? = nil,
                   extra: [String: String] = [:], confidence: Confidence = .confirmed) -> AgentEvent {
            AgentEvent(
                id: EnvelopeContext.eventID(envelope, suffix: suffix),
                provider: .claudeCode,
                sessionID: sessionID,
                kind: kind,
                receivedAt: receivedAt,
                order: EnvelopeContext.order(of: envelope),
                collection: .claudeHook,
                confidence: confidence,
                turnID: payload["prompt_id"]?.stringValue,
                subagentID: (isSubagentLifecycle || subagentID != nil) ? subagentID : nil,
                subagentType: subagentType,
                projectPath: payload["cwd"]?.stringValue,
                sourceEvent: eventName,
                tool: tool,
                attention: attention,
                failure: failure,
                task: task,
                plan: plan,
                origin: EnvelopeContext.origin(of: envelope, transcriptPath: payload["transcript_path"]?.stringValue),
                metadata: metadata.merging(extra) { _, new in new }
            )
        }

        let toolName = payload["tool_name"]?.stringValue
        let tool = toolName.map { ToolInfoBuilder.build(toolName: $0, payload: payload) }

        switch eventName {
        case "SessionStart":
            return [event(.sessionStarted)]

        case "SessionEnd":
            return [event(.sessionEnded)]

        case "UserPromptSubmit":
            return [event(.promptSubmitted)]

        case "PreToolUse":
            guard let tool else { return [] }
            var events = [event(.toolStarted, tool: tool)]
            let input = payload["tool_input"] ?? .object([:])
            if tool.name == "TodoWrite", let plan = ToolInfoBuilder.plan(from: input) {
                events.append(event(.planUpdated, suffix: "plan", plan: plan))
            }
            if tool.name == "TaskUpdate", let id = input["taskId"]?.stringValue ?? input["id"]?.stringValue,
               let status = input["status"]?.stringValue {
                let mapped = ToolInfoBuilder.taskStatus(status)
                events.append(event(mapped == .completed ? .taskCompleted : .taskUpdated, suffix: "task",
                                    task: TaskInfo(id: id, subject: input["subject"]?.stringValue, status: mapped)))
            }
            return events

        case "PostToolUse":
            guard let tool else { return [] }
            return [event(.toolCompleted, tool: tool)]

        case "PostToolUseFailure":
            guard let tool else { return [] }
            let interrupted = payload["is_interrupt"]?.boolValue == true
            let failure = FailureInfo(
                category: interrupted ? .tool : ToolInfoBuilder.failureCategory(for: tool.activity),
                code: interrupted ? "interrupt" : tool.exitCode.map(String.init),
                summary: payload["error"]?.stringValue
            )
            return [event(.toolFailed, tool: tool, failure: failure)]

        case "PostToolBatch":
            let count = payload["tool_calls"]?.arrayValue?.count ?? 0
            return [event(.toolBatchCompleted, extra: ["tool_count": String(count)])]

        case "PermissionRequest":
            guard let tool else { return [] }
            let attention = AttentionInfo(kind: .permission, toolName: tool.name, summary: tool.summary)
            return [event(.permissionRequested, tool: tool, attention: attention)]

        case "PermissionDenied":
            return [event(.permissionDenied, tool: tool, extra: payload["reason"]?.stringValue.map { ["reason": $0] } ?? [:])]

        case "Notification":
            return [notification(payload: payload, make: { kind, attention in event(kind, attention: attention) })]

        case "SubagentStart":
            guard subagentID != nil else { return [] }
            return [event(.subagentStarted)]

        case "SubagentStop":
            guard subagentID != nil else { return [] }
            return [event(.subagentStopped)]

        case "TaskCreated", "TaskCompleted":
            guard let id = payload["task_id"]?.stringValue else { return [] }
            let completed = eventName == "TaskCompleted"
            let task = TaskInfo(id: id, subject: payload["task_subject"]?.stringValue, status: completed ? .completed : .pending)
            return [event(completed ? .taskCompleted : .taskCreated, task: task)]

        case "Stop":
            let background = payload["background_tasks"]?.arrayValue?.count ?? 0
            return [event(.turnCompleted, extra: ["background_tasks": String(background)])]

        case "StopFailure":
            let failure = FailureInfo(
                category: .api,
                code: payload["error"]?.stringValue ?? "unknown",
                summary: payload["error_message"]?.stringValue ?? payload["error_details"]?.stringValue
            )
            return [event(.turnFailed, failure: failure)]

        case "PreCompact":
            return [event(.compactionStarted)]

        case "PostCompact":
            return [event(.compactionFinished)]

        default:
            return [event(.notification)]
        }
    }

    /// Maps `notification_type` values to attention or informational events.
    static func notification(payload: JSONValue, make: (AgentEventKind, AttentionInfo?) -> AgentEvent) -> AgentEvent {
        let type = payload["notification_type"]?.stringValue ?? ""
        let message = payload["message"]?.stringValue
        switch type {
        case "permission_prompt":
            return make(.attentionNeeded, AttentionInfo(kind: .permission, summary: message))
        case "elicitation_dialog", "elicitation_url_dialog":
            return make(.attentionNeeded, AttentionInfo(kind: .elicitation, summary: message))
        case "agent_needs_input", "quota_auto_resume_stale":
            return make(.attentionNeeded, AttentionInfo(kind: .input, summary: message))
        case "idle_prompt":
            return make(.idleReminder, nil)
        default:
            return make(.notification, AttentionInfo(kind: .other, summary: message))
        }
    }
}
