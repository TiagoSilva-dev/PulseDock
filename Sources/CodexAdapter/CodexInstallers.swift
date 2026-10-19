import AdapterSupport
import AgentBridge
import Foundation

/// Locates the Codex CLI and its configuration directory (`CODEX_HOME`, default `~/.codex`).
public struct CodexInstallation: Sendable, Equatable {
    public var executablePath: String?
    public var version: String?
    public var homeDirectory: URL

    public var isInstalled: Bool { executablePath != nil }
    public var hooksURL: URL { homeDirectory.appendingPathComponent("hooks.json") }
    public var configURL: URL { homeDirectory.appendingPathComponent("config.toml") }
}

public enum CodexDetector {
    public static var homeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
    }

    public static let candidatePaths = [
        "~/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.npm-global/bin/codex", "~/.bun/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]

    public static func detect(allowSpawningVersionCheck: Bool = true) -> CodexInstallation {
        let executable = candidatePaths.map { ($0 as NSString).expandingTildeInPath }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        var version: String?
        if let executable, allowSpawningVersionCheck {
            version = runVersion(executable)
        }
        return CodexInstallation(executablePath: executable, version: version, homeDirectory: homeDirectory)
    }

    static func runVersion(_ executable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // "codex-cli 0.120.0" → "0.120.0"
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init)
    }
}

/// Installs PulseDock handlers in `~/.codex/hooks.json`. Codex requires the user to review and
/// trust new hooks with `/hooks` before they run; PulseDock reports them as "waiting for
/// trust" until the first Codex event arrives.
public struct CodexHookInstaller: Sendable {
    public static let ownedMarker = "pulsedock-hook"
    static let eventsWithMatchers: Set<String> = ["PreToolUse", "PermissionRequest", "PostToolUse", "SessionStart",
                                                  "SessionEnd", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]

    public var hooksURL: URL
    public var helperPath: String
    public var backupsDirectory: URL

    public init(
        hooksURL: URL = CodexDetector.homeDirectory.appendingPathComponent("hooks.json"),
        helperPath: String = BridgePaths.installedHelper.path,
        backupsDirectory: URL = BridgePaths.backupsDirectory
    ) {
        self.hooksURL = hooksURL
        self.helperPath = helperPath
        self.backupsDirectory = backupsDirectory
    }

    var editor: HooksSectionEditor {
        HooksSectionEditor { handler in
            (handler["command"]?.stringValue ?? "").contains(CodexHookInstaller.ownedMarker)
        }
    }

    public func command(for event: String) -> String {
        let quoted = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "[ -x \(quoted) ] && exec \(quoted) codex \(event) || exit 0"
    }

    public func handlers() -> [HooksSectionEditor.Handler] {
        CodexNormalizer.supportedHookEvents.map { event in
            HooksSectionEditor.Handler(
                event: event,
                matcher: CodexHookInstaller.eventsWithMatchers.contains(event) ? "*" : nil,
                command: command(for: event),
                // SessionEnd and Interrupt allow at most 3 seconds.
                timeout: (event == "SessionEnd" || event == "Interrupt") ? 2 : 5
            )
        }
    }

    public func planInstall() throws -> ConfigChangePlan {
        let original = try ConfigFileIO.read(hooksURL)
        let root = try parse(original)
        let result = try editor.install(handlers(), into: root)
        return ConfigChangePlan(
            fileURL: hooksURL,
            originalText: original,
            newText: result.root.serialized(),
            addedEvents: CodexNormalizer.supportedHookEvents,
            removedHandlers: result.removedHandlers,
            preservedForeignHandlers: result.foreignHandlers
        )
    }

    public func planUninstall() throws -> ConfigChangePlan {
        guard let original = try ConfigFileIO.read(hooksURL) else {
            return ConfigChangePlan(fileURL: hooksURL, originalText: nil, newText: "", addedEvents: [], removedHandlers: 0, preservedForeignHandlers: 0)
        }
        let root = try parse(original)
        let result = try editor.remove(from: root, dropEmptyHooksKey: false)
        return ConfigChangePlan(
            fileURL: hooksURL,
            originalText: original,
            newText: result.removedHandlers == 0 ? original : result.root.serialized(),
            addedEvents: [],
            removedHandlers: result.removedHandlers,
            preservedForeignHandlers: result.foreignHandlers
        )
    }

    @discardableResult
    public func apply(_ plan: ConfigChangePlan) throws -> URL? {
        guard !plan.isNoOp else { return nil }
        guard try ConfigFileIO.read(plan.fileURL) == plan.originalText else { throw ConfigEditError.changedSinceReview }
        let backup = try ConfigFileIO.backup(plan.fileURL, into: backupsDirectory, prefix: "codex-hooks")
        try ConfigFileIO.writeAtomically(plan.newText, to: plan.fileURL)
        let written = try ConfigFileIO.read(plan.fileURL) ?? ""
        guard let root = try? OrderedJSON.parse(written) else { throw ConfigEditError.validationFailed("unparseable") }
        guard Set(editor.installedEvents(in: root)) == Set(plan.addedEvents) else {
            throw ConfigEditError.validationFailed("unexpected handlers")
        }
        return backup
    }

    public func installedEvents() -> [String] {
        guard let text = try? ConfigFileIO.read(hooksURL), let root = try? parse(text) else { return [] }
        return editor.installedEvents(in: root)
    }

    private func parse(_ text: String?) throws -> OrderedJSON {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .object([]) }
        let root: OrderedJSON
        do { root = try OrderedJSON.parse(text) } catch { throw ConfigEditError.unreadable(String(describing: error)) }
        guard root.objectPairs != nil else { throw ConfigEditError.notAnObject }
        return root
    }
}

/// Optional `notify` integration (turn completion only), for Codex versions without hooks.
///
/// Codex accepts a single `notify` program. If the user already has one, PulseDock stores it
/// in `codex-notify-chain.json` and the helper forwards every notification to it, so the
/// existing integration keeps working. Only a single-line top-level `notify = [...]` is
/// edited automatically; anything else is reported as needing a manual change.
public struct CodexNotifyInstaller: Sendable {
    public var configURL: URL
    public var helperPath: String
    public var chainURL: URL
    public var backupsDirectory: URL

    public init(
        configURL: URL = CodexDetector.homeDirectory.appendingPathComponent("config.toml"),
        helperPath: String = BridgePaths.installedHelper.path,
        chainURL: URL = BridgePaths.supportDirectory.appendingPathComponent("codex-notify-chain.json"),
        backupsDirectory: URL = BridgePaths.backupsDirectory
    ) {
        self.configURL = configURL
        self.helperPath = helperPath
        self.chainURL = chainURL
        self.backupsDirectory = backupsDirectory
    }

    public enum NotifyError: Error, Equatable, LocalizedError {
        case unsupportedLayout
        public var errorDescription: String? {
            "The existing notify setting spans several lines or uses an unsupported form. Edit config.toml manually."
        }
    }

    public struct Plan: Sendable, Equatable {
        public var change: ConfigChangePlan
        /// Previous notify command that will be chained (nil when there was none).
        public var previousCommand: [String]?
    }

    var ownLine: String {
        "notify = [\(tomlString(helperPath)), \"codex-notify\"]"
    }

    public func planInstall() throws -> Plan {
        let original = try ConfigFileIO.read(configURL)
        var lines = (original ?? "").components(separatedBy: "\n")
        let topLevelEnd = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        var previous: [String]?
        if let index = lines[..<topLevelEnd].firstIndex(where: { isNotifyLine($0) }) {
            let line = lines[index]
            if line.contains(CodexHookInstaller.ownedMarker) {
                lines[index] = ownLine
            } else {
                guard line.contains("]"), let parsed = parseArray(line) else { throw NotifyError.unsupportedLayout }
                previous = parsed
                lines[index] = ownLine
            }
        } else {
            lines.insert(ownLine, at: 0)
        }
        let newText = lines.joined(separator: "\n")
        return Plan(
            change: ConfigChangePlan(fileURL: configURL, originalText: original, newText: newText.hasSuffix("\n") ? newText : newText + "\n",
                                     addedEvents: ["notify"], removedHandlers: 0, preservedForeignHandlers: previous == nil ? 0 : 1),
            previousCommand: previous
        )
    }

    @discardableResult
    public func apply(_ plan: Plan) throws -> URL? {
        guard try ConfigFileIO.read(plan.change.fileURL) == plan.change.originalText else { throw ConfigEditError.changedSinceReview }
        if let previous = plan.previousCommand {
            try FileManager.default.createDirectory(at: chainURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(previous).write(to: chainURL, options: .atomic)
        }
        let backup = try ConfigFileIO.backup(plan.change.fileURL, into: backupsDirectory, prefix: "codex-config")
        try ConfigFileIO.writeAtomically(plan.change.newText, to: plan.change.fileURL)
        return backup
    }

    /// Restores the previous notify command (or removes PulseDock's line).
    public func planUninstall() throws -> ConfigChangePlan {
        let original = try ConfigFileIO.read(configURL) ?? ""
        var lines = original.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { isNotifyLine($0) && $0.contains(CodexHookInstaller.ownedMarker) }) {
            if let data = try? Data(contentsOf: chainURL), let previous = try? JSONDecoder().decode([String].self, from: data), !previous.isEmpty {
                lines[index] = "notify = [" + previous.map(tomlString).joined(separator: ", ") + "]"
            } else {
                lines.remove(at: index)
            }
        }
        return ConfigChangePlan(fileURL: configURL, originalText: original, newText: lines.joined(separator: "\n"),
                                addedEvents: [], removedHandlers: 1, preservedForeignHandlers: 0)
    }

    public func applyUninstall(_ plan: ConfigChangePlan) throws {
        guard !plan.isNoOp else { return }
        guard try ConfigFileIO.read(plan.fileURL) == plan.originalText else { throw ConfigEditError.changedSinceReview }
        try ConfigFileIO.backup(plan.fileURL, into: backupsDirectory, prefix: "codex-config")
        try ConfigFileIO.writeAtomically(plan.newText, to: plan.fileURL)
        try? FileManager.default.removeItem(at: chainURL)
    }

    public func isInstalled() -> Bool {
        guard let text = try? ConfigFileIO.read(configURL) else { return false }
        return text.components(separatedBy: "\n").contains { isNotifyLine($0) && $0.contains(CodexHookInstaller.ownedMarker) }
    }

    func isNotifyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("notify") else { return false }
        let rest = trimmed.dropFirst("notify".count).trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("=")
    }

    /// Parses a single-line TOML array of basic or literal strings.
    func parseArray(_ line: String) -> [String]? {
        guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close else { return nil }
        let body = line[line.index(after: open)..<close]
        var values: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for character in body {
            if let active = quote {
                if escaping {
                    switch character {
                    case "n": current.append("\n")
                    case "t": current.append("\t")
                    default: current.append(character)
                    }
                    escaping = false
                } else if character == "\\", active == "\"" {
                    escaping = true
                } else if character == active {
                    values.append(current)
                    current = ""
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character != "," && !character.isWhitespace {
                return nil
            }
        }
        return quote == nil ? values : nil
    }

    func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
