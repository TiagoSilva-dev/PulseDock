import Foundation

/// Maps a concrete tool call to an observable activity. Every rule keys on the tool name
/// or on the literal shell command, never on guesses about intent.
public enum ToolClassifier {
    public static func activity(toolName: String, command: String? = nil) -> ActivityKind {
        switch toolName {
        // Claude Code built-in tools.
        case "Read", "NotebookRead", "view_image":
            return .readingFiles
        case "Glob", "Grep", "LS", "LSP":
            return .searchingCode
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch":
            return .editingCode
        case "Bash", "PowerShell", "exec_command", "shell", "local_shell", "BashOutput", "KillShell", "Monitor":
            return command.map(CommandClassifier.activity(for:)) ?? .runningCommand
        case "WebFetch", "WebSearch", "web_search":
            return .consultingWeb
        case "Agent", "Task", "spawn_agent", "SubagentHandback", "send_input", "wait":
            return .delegating
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "EnterPlanMode", "update_plan":
            return .planning
        case "AskUserQuestion", "request_user_input":
            return .askingUser
        case "ExitPlanMode":
            return .awaitingPlanApproval
        default:
            return .usingTool
        }
    }

    /// Human-facing tool name for MCP tools: `mcp__github__search` becomes `github · search`.
    public static func displayName(toolName: String) -> String {
        guard toolName.hasPrefix("mcp__") else { return toolName }
        let parts = toolName.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return String(toolName.dropFirst(5)) }
        return "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))"
    }
}

/// Classifies shell commands by the programs they run.
public enum CommandClassifier {
    public static func activity(for command: String) -> ActivityKind {
        let subcommands = split(command)
        var best: ActivityKind = .runningCommand
        for words in subcommands {
            let kind = classify(words)
            if rank(kind) > rank(best) { best = kind }
        }
        return best
    }

    /// Short summary for display, for example `swift test` or `npm run build`.
    public static func summary(for command: String, maxLength: Int = 60) -> String {
        let subcommands = split(command)
        let chosen = subcommands.first { classify($0) != .runningCommand } ?? subcommands.first ?? []
        var words: [String] = []
        for word in chosen {
            if word.hasPrefix("-") && words.count >= 2 { break }
            words.append(word)
            if words.count >= 3 { break }
        }
        let text = words.joined(separator: " ")
        return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }

    private static func rank(_ kind: ActivityKind) -> Int {
        switch kind {
        case .runningTests: 4
        case .building: 3
        case .installingDependencies: 2
        case .usingGit: 1
        default: 0
        }
    }

    /// Splits on `&&`, `||`, `;`, `|` and newlines, then tokenises each part, dropping
    /// leading `VAR=value` assignments and common wrappers (`sudo`, `env`, `time`, `npx`…).
    static func split(_ command: String) -> [[String]] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var previous: Character?
        for character in command {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == ";" || character == "\n" || (character == "|" ) || (character == "&" && previous == "&") {
                if character == "&" { current.removeLast() }
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        parts.append(current)
        return parts.compactMap { part -> [String]? in
            var words = part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
                String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()"))
            }.filter { !$0.isEmpty }
            while let first = words.first, first.contains("="), !first.hasPrefix("-"), first.first?.isLetter == true {
                words.removeFirst()
            }
            while let first = words.first, wrappers.contains(first) {
                words.removeFirst()
                while let next = words.first, next.hasPrefix("-") { words.removeFirst() }
            }
            if let first = words.first, first.contains("/") {
                words[0] = String(first.split(separator: "/").last ?? Substring(first))
            }
            return words.isEmpty ? nil : words
        }
    }

    private static let wrappers: Set<String> = ["sudo", "env", "time", "nice", "command", "exec", "npx", "bunx", "pnpx", "xcrun", "caffeinate"]

    private static let testRunners: Set<String> = [
        "pytest", "jest", "vitest", "mocha", "rspec", "phpunit", "ctest", "tox", "nox", "ava", "karma", "playwright", "cypress",
    ]
    private static let buildTools: Set<String> = ["tsc", "webpack", "esbuild", "rollup", "vite", "cmake", "ninja", "bazel", "msbuild", "make", "xcodebuild"]

    static func classify(_ words: [String]) -> ActivityKind {
        guard let program = words.first?.lowercased() else { return .runningCommand }
        let args = words.dropFirst().map { $0.lowercased() }
        let first = args.first
        let second = args.dropFirst().first

        if testRunners.contains(program) { return .runningTests }
        switch program {
        case "swift":
            if first == "test" { return .runningTests }
            if first == "build" { return .building }
            if first == "package" && (second == "resolve" || second == "update") { return .installingDependencies }
        case "xcodebuild":
            if args.contains("test") || args.contains("test-without-building") { return .runningTests }
            return .building
        case "npm", "pnpm", "yarn", "bun":
            if first == "test" || first == "t" || (first == "run" && (second?.hasPrefix("test") ?? false)) { return .runningTests }
            if first == "run" && (second?.hasPrefix("build") ?? false) { return .building }
            if first == "build" { return .building }
            if first == "install" || first == "i" || first == "ci" || first == "add" { return .installingDependencies }
        case "go":
            if first == "test" { return .runningTests }
            if first == "build" { return .building }
            if first == "get" || (first == "mod" && second == "download") { return .installingDependencies }
        case "cargo":
            if first == "test" || first == "nextest" { return .runningTests }
            if first == "build" || first == "check" { return .building }
        case "python", "python3":
            if first == "-m", let module = second {
                if module == "pytest" || module == "unittest" { return .runningTests }
                if module == "pip" { return .installingDependencies }
            }
        case "pip", "pip3", "uv", "poetry", "pod", "brew", "bundle":
            if program == "bundle", first == "exec", second == "rspec" { return .runningTests }
            if program == "uv", first == "run", second == "pytest" { return .runningTests }
            if first == "install" || first == "add" || first == "sync" || first == "update" { return .installingDependencies }
        case "mvn", "gradle", "gradlew":
            if args.contains("test") { return .runningTests }
            if args.contains("build") || args.contains("package") || args.contains("assemble") { return .building }
        case "dotnet", "deno", "mix", "flutter", "dart":
            if first == "test" { return .runningTests }
            if first == "build" || first == "compile" { return .building }
        case "make":
            if args.contains("test") || args.contains("check") { return .runningTests }
            return .building
        case "git", "gh":
            return .usingGit
        default:
            break
        }
        if buildTools.contains(program) { return .building }
        return .runningCommand
    }
}
