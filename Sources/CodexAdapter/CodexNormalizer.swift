import AdapterSupport
import AgentBridge
import AgentCore
import Foundation

/// Converts sanitized Codex hook and `notify` envelopes into `AgentEvent`s.
///
/// Hook field names follow the generated schemas in `openai/codex/codex-rs/hooks/schema`.
/// Codex differences from Claude Code that matter here:
/// - turn-scoped events carry `turn_id`;
/// - there is no `PostToolUseFailure`: Bash failures arrive as `PostToolUse` with a non-zero
///   exit status in `tool_response`;
/// - user interrupts are reported by the `Interrupt` hook;
/// - `notify` only reports `agent-turn-complete`.
public enum CodexNormalizer {
    public static let supportedHookEvents: [String] = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "SubagentStart", "SubagentStop", "Stop", "Interrupt", "PreCompact", "PostCompact",
    ]

    public static func normalize(_ envelope: BridgeEnvelope, receivedAt: Date = Date()) -> [AgentEvent] {
        guard envelope.source == .codex else { return [] }
        switch envelope.kind {
        case .hook: return normalizeHook(envelope, receivedAt: receivedAt)
        case .notify: return normalizeNotify(envelope, receivedAt: receivedAt)
        case .control: return []
        }
    }

    static func normalizeHook(_ envelope: BridgeEnvelope, receivedAt: Date) -> [AgentEvent] {
        let payload = envelope.payload
        guard let sessionID = payload["session_id"]?.stringValue, !sessionID.isEmpty else { return [] }
        let name = envelope.event
        let subagentID = payload["agent_id"]?.stringValue
        let metadata = EnvelopeContext.metadata(from: payload, keys: ["permission_mode", "model", "source", "reason", "trigger"])

        func event(_ kind: AgentEventKind, suffix: String? = nil, tool: ToolInfo? = nil, attention: AttentionInfo? = nil,
                   failure: FailureInfo? = nil, plan: PlanSnapshot? = nil, extra: [String: String] = [:]) -> AgentEvent {
            AgentEvent(
                id: EnvelopeContext.eventID(envelope, suffix: suffix),
                provider: .codex,
                sessionID: sessionID,
                kind: kind,
                receivedAt: receivedAt,
                order: EnvelopeContext.order(of: envelope),
                collection: .codexHook,
                turnID: payload["turn_id"]?.stringValue,
                subagentID: subagentID,
                subagentType: payload["agent_type"]?.stringValue,
                projectPath: payload["cwd"]?.stringValue,
                sourceEvent: name,
                tool: tool,
                attention: attention,
                failure: failure,
                plan: plan,
                origin: EnvelopeContext.origin(of: envelope, transcriptPath: payload["transcript_path"]?.stringValue),
                metadata: metadata.merging(extra) { _, new in new }
            )
        }

        let tool = payload["tool_name"]?.stringValue.map { ToolInfoBuilder.build(toolName: $0, payload: payload) }

        switch name {
        case "SessionStart":
            return [event(.sessionStarted)]
        case "SessionEnd":
            return [event(.sessionEnded)]
        case "UserPromptSubmit":
            return [event(.promptSubmitted, extra: payload["command"]?.stringValue.map { ["command": $0] } ?? [:])]
        case "PreToolUse":
            guard let tool else { return [] }
            var events = [event(.toolStarted, tool: tool)]
            if tool.name == "update_plan", let plan = ToolInfoBuilder.plan(from: payload["tool_input"] ?? .object([:])) {
                events.append(event(.planUpdated, suffix: "plan", plan: plan))
            }
            return events
        case "PermissionRequest":
            guard let tool else { return [] }
            let reason = payload["tool_input"]?["description"]?.stringValue
            return [event(.permissionRequested, tool: tool, attention: AttentionInfo(kind: .permission, toolName: tool.name, summary: tool.summary, reason: reason))]
        case "PostToolUse":
            guard let tool else { return [] }
            if let code = tool.exitCode, code != 0 {
                let failure = FailureInfo(category: ToolInfoBuilder.failureCategory(for: tool.activity), code: String(code), summary: "Exit code \(code)")
                return [event(.toolFailed, tool: tool, failure: failure)]
            }
            return [event(.toolCompleted, tool: tool)]
        case "SubagentStart":
            guard subagentID != nil else { return [] }
            return [event(.subagentStarted)]
        case "SubagentStop":
            guard subagentID != nil else { return [] }
            return [event(.subagentStopped)]
        case "Stop":
            return [event(.turnCompleted)]
        case "Interrupt":
            return [event(.turnInterrupted)]
        case "PreCompact":
            return [event(.compactionStarted)]
        case "PostCompact":
            return [event(.compactionFinished)]
        default:
            return [event(.notification)]
        }
    }

    /// `notify` reports only the end of a turn. Nothing is claimed about activity between
    /// notifications.
    static func normalizeNotify(_ envelope: BridgeEnvelope, receivedAt: Date) -> [AgentEvent] {
        let payload = envelope.payload
        guard envelope.event == "agent-turn-complete",
              let threadID = payload["thread-id"]?.stringValue, !threadID.isEmpty else { return [] }
        return [AgentEvent(
            id: envelope.id,
            provider: .codex,
            sessionID: threadID,
            kind: .turnCompleted,
            receivedAt: receivedAt,
            order: EnvelopeContext.order(of: envelope),
            collection: .codexNotify,
            turnID: payload["turn-id"]?.stringValue,
            projectPath: payload["cwd"]?.stringValue,
            sourceEvent: "agent-turn-complete",
            origin: EnvelopeContext.origin(of: envelope, transcriptPath: nil)
        )]
    }
}
