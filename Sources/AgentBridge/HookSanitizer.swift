import Foundation

/// Privacy options applied by the hook helper. Written by the app to
/// `BridgePaths.helperConfig`; defaults are used when the file is absent.
public struct SanitizerOptions: Codable, Sendable, Hashable {
    public enum CommandDetail: String, Codable, Sendable, CaseIterable {
        /// The command line, with credentials redacted and length capped.
        case redacted
        /// Only the program and its first argument (for example `swift test`).
        case program
        /// No command text at all.
        case none
    }

    public var commandDetail: CommandDetail
    public var keepFilePaths: Bool
    public var keepSearchQueries: Bool

    public init(commandDetail: CommandDetail = .redacted, keepFilePaths: Bool = true, keepSearchQueries: Bool = true) {
        self.commandDetail = commandDetail
        self.keepFilePaths = keepFilePaths
        self.keepSearchQueries = keepSearchQueries
    }

    public static func load(from url: URL = BridgePaths.helperConfig) -> SanitizerOptions {
        guard let data = try? Data(contentsOf: url), data.count < 16_384,
              let options = try? JSONDecoder().decode(SanitizerOptions.self, from: data) else {
            return SanitizerOptions()
        }
        return options
    }

    public func save(to url: URL = BridgePaths.helperConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Whitelist-based sanitization of hook payloads, performed inside the helper so prompts,
/// file contents, command output, diffs and assistant messages never reach the socket.
///
/// Only fields listed here survive. Unknown fields (including ones added by future agent
/// versions) are dropped by default.
public enum HookSanitizer {
    // MARK: Field whitelists

    /// Identifier-like strings kept verbatim (length-capped).
    private static let identifierFields: [String: Int] = [
        "session_id": 160, "prompt_id": 80, "cwd": 1024, "permission_mode": 32, "hook_event_name": 64,
        "agent_id": 160, "agent_type": 128, "transcript_path": 1024, "turn_id": 160, "model": 128,
        "source": 32, "reason": 64, "notification_type": 64, "tool_name": 160, "tool_use_id": 160,
        "task_id": 160, "teammate_name": 96, "trigger": 16,
    ]

    /// Free text written by the agent or the user (redacted and capped).
    private static let textFields: [String: Int] = [
        "title": 80, "message": 200, "session_title": 80, "task_subject": 120, "error_details": 160,
    ]

    private static let booleanFields: Set<String> = ["stop_hook_active", "is_interrupt"]
    private static let numberFields: Set<String> = ["duration_ms", "seconds_since_last_response"]

    // MARK: Entry points

    public static func sanitize(event: String, input: [String: Any], options: SanitizerOptions = SanitizerOptions()) -> JSONValue {
        var out: [String: JSONValue] = [:]

        for (key, limit) in identifierFields {
            if let value = input[key] as? String, !value.isEmpty {
                out[key] = .string(String(value.prefix(limit)))
            }
        }
        for (key, limit) in textFields {
            if let value = input[key] as? String, !value.isEmpty {
                out[key] = .string(SecretRedactor.clean(value, maxLength: limit))
            }
        }
        for key in booleanFields {
            if let value = input[key] as? Bool { out[key] = .bool(value) }
        }
        for key in numberFields {
            if let value = input[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
                out[key] = .number(value.doubleValue)
            }
        }

        // `error` is an enum on StopFailure and free text (command output) on tool failures.
        if let error = input["error"] as? String {
            if event == "StopFailure" {
                out["error"] = .string(String(error.prefix(48)))
            } else {
                out["error"] = .string(SecretRedactor.firstLine(error, maxLength: 120))
            }
        }
        if event == "StopFailure", let message = input["last_assistant_message"] as? String {
            out["error_message"] = .string(SecretRedactor.firstLine(message, maxLength: 160))
        }

        if let prompt = input["prompt"] as? String, let command = slashCommand(prompt) {
            out["command"] = .string(command)
        }
        if let server = input["mcp_server"] as? [String: Any] {
            var object: [String: JSONValue] = [:]
            if let name = server["name"] as? String { object["name"] = .string(String(name.prefix(96))) }
            if let origin = server["source"] as? String { object["source"] = .string(String(origin.prefix(32))) }
            out["mcp_server"] = .object(object)
        }
        if let effort = input["effort"] as? [String: Any], let level = effort["level"] as? String {
            out["effort"] = .string(String(level.prefix(16)))
        }
        if let tasks = input["background_tasks"] as? [[String: Any]] {
            out["background_tasks"] = .array(tasks.prefix(20).map { task in
                var object: [String: JSONValue] = [:]
                if let type = task["type"] as? String { object["type"] = .string(String(type.prefix(32))) }
                if let status = task["status"] as? String { object["status"] = .string(String(status.prefix(32))) }
                if let agentType = task["agent_type"] as? String { object["agent_type"] = .string(String(agentType.prefix(96))) }
                return .object(object)
            })
        }
        if let crons = input["session_crons"] as? [Any] {
            out["session_crons_count"] = .number(Double(crons.count))
        }
        if let suggestions = input["permission_suggestions"] as? [Any] {
            out["permission_suggestions_count"] = .number(Double(suggestions.count))
        }
        if let calls = input["tool_calls"] as? [[String: Any]] {
            out["tool_calls"] = .array(calls.prefix(64).map { call in
                var object: [String: JSONValue] = [:]
                if let name = call["tool_name"] as? String { object["tool_name"] = .string(String(name.prefix(160))) }
                if let id = call["tool_use_id"] as? String { object["tool_use_id"] = .string(String(id.prefix(160))) }
                return .object(object)
            })
        }

        let toolName = input["tool_name"] as? String ?? ""
        if !toolName.isEmpty, input["tool_input"] != nil {
            out["tool_input"] = sanitizeToolInput(toolName: toolName, input: input["tool_input"], options: options)
        }
        if !toolName.isEmpty, let response = input["tool_response"] {
            if let sanitized = sanitizeToolResponse(toolName: toolName, response: response) {
                out["tool_response"] = sanitized
            }
        }
        return .object(out)
    }

    /// Codex `notify` payloads: identifiers only. `input-messages` and
    /// `last-assistant-message` (conversation content) are dropped.
    public static func sanitizeNotify(input: [String: Any]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for (key, limit) in ["type": 64, "thread-id": 160, "turn-id": 160, "cwd": 1024] {
            if let value = input[key] as? String, !value.isEmpty {
                out[key] = .string(String(value.prefix(limit)))
            }
        }
        return .object(out)
    }

    // MARK: Tool input

    static func sanitizeToolInput(toolName: String, input: Any?, options: SanitizerOptions) -> JSONValue {
        guard let input = input as? [String: Any] else { return .object([:]) }
        var out: [String: JSONValue] = [:]
        switch toolName {
        case "Bash", "PowerShell", "exec_command", "shell", "local_shell":
            if let command = commandString(input["command"]) ?? (input["cmd"] as? String) {
                let sanitized = sanitizeCommand(command, detail: options.commandDetail)
                if !sanitized.isEmpty { out["command"] = .string(sanitized) }
            }
            if let description = input["description"] as? String {
                out["description"] = .string(SecretRedactor.clean(description, maxLength: 120))
            }
            if let background = input["run_in_background"] as? Bool { out["run_in_background"] = .bool(background) }

        case "apply_patch":
            if let patch = commandString(input["command"]) ?? (input["patch"] as? String) ?? (input["input"] as? String) {
                let files = patchFiles(patch)
                out["files"] = .array(files.prefix(40).map { .string(options.keepFilePaths ? $0 : ($0 as NSString).lastPathComponent) })
            }

        case "Read", "NotebookRead", "Write", "Edit", "MultiEdit", "NotebookEdit", "view_image":
            if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
                out["file_path"] = .string(options.keepFilePaths ? String(path.prefix(1024)) : (path as NSString).lastPathComponent)
            }
            if let edits = input["edits"] as? [Any] { out["edit_count"] = .number(Double(edits.count)) }

        case "Glob", "Grep":
            if options.keepSearchQueries, let pattern = input["pattern"] as? String {
                out["pattern"] = .string(SecretRedactor.clean(pattern, maxLength: 80))
            }
            if options.keepFilePaths, let path = input["path"] as? String { out["path"] = .string(String(path.prefix(1024))) }
            if let glob = input["glob"] as? String { out["glob"] = .string(SecretRedactor.clean(glob, maxLength: 60)) }

        case "WebFetch":
            if let url = input["url"] as? String { out["url"] = .string(sanitizeURL(url)) }

        case "WebSearch", "web_search":
            if options.keepSearchQueries, let query = input["query"] as? String {
                out["query"] = .string(SecretRedactor.clean(query, maxLength: 80))
            }

        case "Agent", "Task", "spawn_agent":
            if let description = input["description"] as? String {
                out["description"] = .string(SecretRedactor.clean(description, maxLength: 120))
            }
            if let type = (input["subagent_type"] ?? input["agent_type"]) as? String {
                out["subagent_type"] = .string(String(type.prefix(96)))
            }
            if let background = input["run_in_background"] as? Bool { out["run_in_background"] = .bool(background) }

        case "TodoWrite":
            if let todos = input["todos"] as? [[String: Any]] {
                out["todos"] = .array(todos.prefix(40).map { todo in
                    let title = (todo["content"] as? String) ?? (todo["activeForm"] as? String) ?? ""
                    return .object([
                        "content": .string(SecretRedactor.clean(title, maxLength: 80)),
                        "status": .string(String(((todo["status"] as? String) ?? "pending").prefix(16))),
                    ])
                })
            }

        case "TaskCreate", "TaskUpdate":
            for key in ["subject", "activeForm"] {
                if let value = input[key] as? String { out[key] = .string(SecretRedactor.clean(value, maxLength: 120)) }
            }
            for key in ["taskId", "id", "status"] {
                if let value = JSONValue(any: input[key]).stringValue, input[key] != nil {
                    out[key] = .string(String(value.prefix(64)))
                }
            }

        case "update_plan":
            if let plan = input["plan"] as? [[String: Any]] {
                out["plan"] = .array(plan.prefix(40).map { step in
                    .object([
                        "step": .string(SecretRedactor.clean((step["step"] as? String) ?? "", maxLength: 80)),
                        "status": .string(String(((step["status"] as? String) ?? "pending").prefix(16))),
                    ])
                })
            }

        case "AskUserQuestion":
            if let questions = input["questions"] as? [[String: Any]] {
                out["question_count"] = .number(Double(questions.count))
                if let first = questions.first?["question"] as? String {
                    out["question"] = .string(SecretRedactor.clean(first, maxLength: 120))
                }
            }

        default:
            // MCP and unknown tools: arguments are dropped entirely.
            break
        }
        return .object(out)
    }

    // MARK: Tool response

    static func sanitizeToolResponse(toolName: String, response: Any) -> JSONValue? {
        var out: [String: JSONValue] = [:]
        if let object = response as? [String: Any] {
            if let interrupted = object["interrupted"] as? Bool { out["interrupted"] = .bool(interrupted) }
            if let code = exitCode(in: object) { out["exit_code"] = .number(Double(code)) }
            if let diff = object["bashEditDiff"] as? [String: Any], let files = diff["changedFiles"] as? [String] {
                out["changed_files"] = .array(files.prefix(20).map { .string(String($0.prefix(1024))) })
            }
            if let type = object["type"] as? String, toolName == "Write" { out["write_type"] = .string(String(type.prefix(16))) }
            if let success = object["success"] as? Bool { out["success"] = .bool(success) }
            if toolName == "Agent" || toolName == "Task" {
                if let status = object["status"] as? String { out["status"] = .string(String(status.prefix(32))) }
                if let agentID = object["agentId"] as? String { out["agent_id"] = .string(String(agentID.prefix(160))) }
                for key in ["totalDurationMs", "totalToolUseCount"] {
                    if let value = object[key] as? NSNumber { out[key] = .number(value.doubleValue) }
                }
            }
        } else if let text = response as? String, let code = exitCode(inText: text) {
            out["exit_code"] = .number(Double(code))
        }
        return out.isEmpty ? nil : .object(out)
    }

    private static func exitCode(in object: [String: Any]) -> Int? {
        for key in ["exit_code", "exitCode", "returnCode"] {
            if let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        }
        if let metadata = object["metadata"] as? [String: Any], let number = metadata["exit_code"] as? NSNumber {
            return number.intValue
        }
        if let output = object["output"] as? String { return exitCode(inText: output) }
        return nil
    }

    private static let exitCodeExpression = try? NSRegularExpression(pattern: #"(?i)(?:exit(?:ed)?(?: with)? code|exit status|process exited with code)[:= ]+(-?\d{1,4})"#)

    static func exitCode(inText text: String) -> Int? {
        let head = String(text.prefix(4000))
        if head.hasPrefix("{"), let data = head.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = exitCode(in: object) {
            return code
        }
        guard let expression = exitCodeExpression,
              let match = expression.firstMatch(in: head, range: NSRange(head.startIndex..<head.endIndex, in: head)),
              let range = Range(match.range(at: 1), in: head) else { return nil }
        return Int(head[range])
    }

    // MARK: Helpers

    /// Codex may send the shell command as an argv array (`["bash", "-lc", "…"]`).
    static func commandString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let parts = value as? [String], !parts.isEmpty {
            if parts.count >= 3, ["bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"].contains(parts[0]), parts[1].hasPrefix("-") {
                return parts[2...].joined(separator: " ")
            }
            return parts.joined(separator: " ")
        }
        return nil
    }

    static func sanitizeCommand(_ command: String, detail: SanitizerOptions.CommandDetail) -> String {
        switch detail {
        case .none:
            return ""
        case .redacted:
            return SecretRedactor.clean(command, maxLength: 240)
        case .program:
            let words = SecretRedactor.clean(command, maxLength: 240)
                .split(separator: " ")
                .drop { $0.contains("=") && $0.first?.isLetter == true }
            let program = words.prefix(2).filter { !$0.hasPrefix("-") }
            return program.joined(separator: " ")
        }
    }

    /// File paths named in an `apply_patch` envelope (the patch body is discarded).
    static func patchFiles(_ patch: String) -> [String] {
        var files: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(prefix) {
                let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, !files.contains(path) { files.append(String(path.prefix(1024))) }
            }
        }
        return files
    }

    /// Keeps scheme, host and path; drops credentials, query and fragment.
    static func sanitizeURL(_ text: String) -> String {
        guard var components = URLComponents(string: text), components.host != nil else {
            return SecretRedactor.clean(text.components(separatedBy: "?").first ?? "", maxLength: 160)
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return SecretRedactor.clean(components.string ?? "", maxLength: 160)
    }

    static func slashCommand(_ prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), let first = trimmed.split(separator: " ", maxSplits: 1).first else { return nil }
        let name = String(first.prefix(48))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/:_-."))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }), name.count > 1 else { return nil }
        return name
    }
}
