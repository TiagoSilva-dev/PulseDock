import AgentBridge
import AgentCore
import Foundation

/// Shared helpers for turning sanitized envelopes into `AgentEvent`s.
public enum EnvelopeContext {
    /// Ordering key from the helper's timestamps.
    public static func order(of envelope: BridgeEnvelope) -> EventOrder {
        EventOrder(wallMillis: envelope.ts, bootID: envelope.boot, monotonicNanos: envelope.mono)
    }

    /// Session origin derived from the process chain captured by the helper.
    public static func origin(of envelope: BridgeEnvelope, transcriptPath: String?) -> SessionOrigin? {
        guard let context = envelope.ctx else {
            return transcriptPath.map { SessionOrigin(transcriptPath: $0) }
        }
        let agent = ProcessInspector.agentProcess(in: context)
        let host = ProcessInspector.hostApplication(in: context)
        let hostBundleID = host.flatMap { ProcessInspector.bundleIdentifier(atPath: $0.bundlePath) }
            ?? context.env["__CFBundleIdentifier"]
        return SessionOrigin(
            agentPID: agent?.pid,
            agentStartTime: agent?.start,
            hostAppBundleID: hostBundleID,
            hostAppPID: host?.entry.pid,
            hostAppPath: host?.bundlePath,
            tty: context.tty,
            terminalProgram: context.env["TERM_PROGRAM"],
            terminalSessionID: context.env["TERM_SESSION_ID"] ?? context.env["ITERM_SESSION_ID"],
            tmuxPane: context.env["TMUX_PANE"],
            entrypoint: context.env["CLAUDE_CODE_ENTRYPOINT"],
            projectRoot: context.env["CLAUDE_PROJECT_DIR"],
            transcriptPath: transcriptPath
        )
    }

    /// Metadata copied from the payload when present.
    public static func metadata(from payload: JSONValue, keys: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            if let value = payload[key]?.stringValue, !value.isEmpty { result[key] = value }
        }
        return result
    }

    public static func eventID(_ envelope: BridgeEnvelope, suffix: String? = nil) -> String {
        suffix.map { "\(envelope.id)-\($0)" } ?? envelope.id
    }
}

/// Builds `ToolInfo` from a sanitized tool payload. Shared by Claude Code and Codex.
public enum ToolInfoBuilder {
    public static func build(toolName: String, payload: JSONValue) -> ToolInfo {
        let input = payload["tool_input"] ?? .object([:])
        let response = payload["tool_response"]
        let command = input["command"]?.stringValue
        let activity = ToolClassifier.activity(toolName: toolName, command: command)

        var filePaths: [String] = []
        if let path = input["file_path"]?.stringValue { filePaths.append(path) }
        if let files = input["files"]?.arrayValue { filePaths.append(contentsOf: files.compactMap(\.stringValue)) }
        if let changed = response?["changed_files"]?.arrayValue { filePaths.append(contentsOf: changed.compactMap(\.stringValue)) }

        var exitCode = response?["exit_code"]?.intValue
        if exitCode == nil, let error = payload["error"]?.stringValue {
            exitCode = parseExitCode(error)
        }

        return ToolInfo(
            name: toolName,
            useID: payload["tool_use_id"]?.stringValue,
            activity: activity,
            summary: summary(toolName: toolName, input: input),
            durationMillis: payload["duration_ms"]?.intValue,
            exitCode: exitCode,
            inputFingerprint: fingerprint(toolName: toolName, input: input),
            filePaths: Array(filePaths.prefix(40))
        )
    }

    /// Short human summary derived from sanitized fields only.
    public static func summary(toolName: String, input: JSONValue) -> String? {
        if let command = input["command"]?.stringValue, !command.isEmpty {
            return CommandClassifier.summary(for: command)
        }
        if let path = input["file_path"]?.stringValue { return (path as NSString).lastPathComponent }
        if let files = input["files"]?.arrayValue, let first = files.first?.stringValue {
            let name = (first as NSString).lastPathComponent
            return files.count > 1 ? "\(name) +\(files.count - 1)" : name
        }
        if let pattern = input["pattern"]?.stringValue { return pattern }
        if let url = input["url"]?.stringValue { return URL(string: url)?.host ?? url }
        if let query = input["query"]?.stringValue { return query }
        if let description = input["description"]?.stringValue { return description }
        if let type = input["subagent_type"]?.stringValue { return type }
        if let question = input["question"]?.stringValue { return question }
        if let subject = input["subject"]?.stringValue { return subject }
        if toolName.hasPrefix("mcp__") { return ToolClassifier.displayName(toolName: toolName) }
        return nil
    }

    /// Fingerprint over the fields that identify a call (not descriptions), so a permission
    /// request can be matched to the tool result that follows it.
    public static func fingerprint(toolName: String, input: JSONValue) -> String {
        var hasher = StableHasher()
        hasher.combine(toolName)
        for key in ["command", "file_path", "url", "pattern", "query", "path", "subagent_type"] {
            if let value = input[key]?.stringValue { hasher.combine("\(key)=\(value)") }
        }
        if let files = input["files"]?.arrayValue {
            hasher.combine("files=" + files.compactMap(\.stringValue).joined(separator: ","))
        }
        return hasher.hexDigest
    }

    public static func parseExitCode(_ text: String) -> Int? {
        let lower = text.lowercased()
        guard let range = lower.range(of: "exit code") else { return nil }
        let digits = lower[range.upperBound...].drop { $0 == " " || $0 == ":" }.prefix { $0 == "-" || $0.isNumber }
        return Int(digits)
    }

    /// Failure category for a failed tool call, from its observed activity.
    public static func failureCategory(for activity: ActivityKind) -> FailureCategory {
        switch activity {
        case .runningTests: .tests
        case .building: .build
        default: .tool
        }
    }

    /// Plan steps from `TodoWrite` (Claude Code) or `update_plan` (Codex).
    public static func plan(from input: JSONValue) -> PlanSnapshot? {
        if let todos = input["todos"]?.arrayValue {
            let steps = todos.compactMap { todo -> PlanStep? in
                guard let title = todo["content"]?.stringValue else { return nil }
                return PlanStep(title: title, status: taskStatus(todo["status"]?.stringValue))
            }
            return steps.isEmpty ? nil : PlanSnapshot(steps: steps, source: "todo")
        }
        if let plan = input["plan"]?.arrayValue {
            let steps = plan.compactMap { step -> PlanStep? in
                guard let title = step["step"]?.stringValue else { return nil }
                return PlanStep(title: title, status: taskStatus(step["status"]?.stringValue))
            }
            return steps.isEmpty ? nil : PlanSnapshot(steps: steps, source: "plan")
        }
        return nil
    }

    public static func taskStatus(_ text: String?) -> TaskStatus {
        switch text?.lowercased() {
        case "completed", "complete", "done": .completed
        case "in_progress", "inprogress", "in-progress", "active": .inProgress
        default: .pending
        }
    }
}
