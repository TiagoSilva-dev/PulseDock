import AdapterSupport
import AgentBridge
import Foundation

/// Installs and removes PulseDock's Claude Code hooks in the user settings file
/// (`~/.claude/settings.json`), so no project needs to be edited.
///
/// The flow is preview → explicit consent → backup → surgical write → validation. Only
/// handlers whose command references `pulsedock-hook` are ever touched.
public struct ClaudeCodeHookInstaller: Sendable {
    public static let ownedMarker = "pulsedock-hook"

    /// Events observed by PulseDock (all documented in the hooks reference).
    public static let modernEvents = ClaudeCodeNormalizer.supportedEvents
    /// Conservative set for older Claude Code versions.
    public static let legacyEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                      "Notification", "SubagentStop", "Stop", "PreCompact"]
    /// Events whose matcher filters tool or notification names; PulseDock matches all.
    static let eventsWithMatchers: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
                                                  "PermissionDenied", "Notification", "SubagentStart", "SubagentStop",
                                                  "SessionStart", "SessionEnd", "PreCompact", "PostCompact", "StopFailure"]

    public var settingsURL: URL
    public var helperPath: String
    public var backupsDirectory: URL

    public init(
        settingsURL: URL = ClaudeCodeDetector.defaultSettingsURL,
        helperPath: String = BridgePaths.installedHelper.path,
        backupsDirectory: URL = BridgePaths.backupsDirectory
    ) {
        self.settingsURL = settingsURL
        self.helperPath = helperPath
        self.backupsDirectory = backupsDirectory
    }

    var editor: HooksSectionEditor {
        HooksSectionEditor { handler in
            (handler["command"]?.stringValue ?? "").contains(ClaudeCodeHookInstaller.ownedMarker)
        }
    }

    /// Shell command for one event. `exec` hands the process over to the helper (so its parent
    /// is Claude Code itself); the existence check keeps Claude Code quiet if PulseDock was
    /// removed without uninstalling the hooks.
    public func command(for event: String) -> String {
        let quoted = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "[ -x \(quoted) ] && exec \(quoted) claude-code \(event) || exit 0"
    }

    public static func events(forVersion version: String?) -> [String] {
        guard let version, let parsed = SemanticVersion(version) else { return modernEvents }
        return parsed >= SemanticVersion(major: 2, minor: 1, patch: 200) ? modernEvents : legacyEvents
    }

    public func handlers(events: [String]) -> [HooksSectionEditor.Handler] {
        events.map { event in
            HooksSectionEditor.Handler(
                event: event,
                matcher: ClaudeCodeHookInstaller.eventsWithMatchers.contains(event) ? "*" : nil,
                command: command(for: event),
                // SessionEnd shares a 1.5 s budget; the helper finishes in milliseconds.
                timeout: event == "SessionEnd" ? 1 : 5
            )
        }
    }

    // MARK: Plans

    public func planInstall(version: String?) throws -> ConfigChangePlan {
        let original = try ConfigFileIO.read(settingsURL)
        let root = try parseRoot(original)
        let events = ClaudeCodeHookInstaller.events(forVersion: version)
        let result = try editor.install(handlers(events: events), into: root)
        return ConfigChangePlan(
            fileURL: settingsURL,
            originalText: original,
            newText: result.root.serialized(),
            addedEvents: events,
            removedHandlers: result.removedHandlers,
            preservedForeignHandlers: result.foreignHandlers
        )
    }

    public func planUninstall() throws -> ConfigChangePlan {
        let original = try ConfigFileIO.read(settingsURL)
        guard let original else {
            return ConfigChangePlan(fileURL: settingsURL, originalText: nil, newText: "", addedEvents: [], removedHandlers: 0, preservedForeignHandlers: 0)
        }
        let root = try parseRoot(original)
        let hadOnlyOurHooks = editor.installedEvents(in: root).count == (root["hooks"]?.objectPairs?.count ?? 0)
        let result = try editor.remove(from: root, dropEmptyHooksKey: hadOnlyOurHooks)
        return ConfigChangePlan(
            fileURL: settingsURL,
            originalText: original,
            newText: result.removedHandlers == 0 ? original : result.root.serialized(),
            addedEvents: [],
            removedHandlers: result.removedHandlers,
            preservedForeignHandlers: result.foreignHandlers
        )
    }

    /// Applies a reviewed plan. Returns the backup location (if a file existed).
    @discardableResult
    public func apply(_ plan: ConfigChangePlan) throws -> URL? {
        guard !plan.isNoOp else { return nil }
        let current = try ConfigFileIO.read(plan.fileURL)
        guard current == plan.originalText else { throw ConfigEditError.changedSinceReview }
        let backup = try ConfigFileIO.backup(plan.fileURL, into: backupsDirectory, prefix: "claude-settings")
        try ConfigFileIO.writeAtomically(plan.newText, to: plan.fileURL)
        // Validate: the file must parse and contain exactly the intended PulseDock handlers.
        let written = try ConfigFileIO.read(plan.fileURL) ?? ""
        let root: OrderedJSON
        do {
            root = try OrderedJSON.parse(written)
        } catch {
            throw ConfigEditError.validationFailed(String(describing: error))
        }
        let installed = Set(editor.installedEvents(in: root))
        guard installed == Set(plan.addedEvents) else {
            throw ConfigEditError.validationFailed("expected \(plan.addedEvents.count) events, found \(installed.count)")
        }
        return backup
    }

    // MARK: Status

    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed(events: [String])
        /// Some PulseDock events are missing (for example after a manual edit).
        case incomplete(installed: [String], missing: [String])
        /// PulseDock handlers exist but point to another helper path.
        case outdated(events: [String])
        case unreadable(String)
    }

    public func status(version: String?) -> Status {
        do {
            let text = try ConfigFileIO.read(settingsURL)
            let root = try parseRoot(text)
            let installed = editor.installedEvents(in: root)
            guard !installed.isEmpty else { return .notInstalled }
            let expected = ClaudeCodeHookInstaller.events(forVersion: version)
            let commands = allOwnedCommands(in: root)
            if commands.contains(where: { !$0.contains(helperPath) }) { return .outdated(events: installed) }
            let missing = expected.filter { !installed.contains($0) }
            // Report in canonical order regardless of where entries sit in the file.
            let ordered = expected.filter(installed.contains) + installed.filter { !expected.contains($0) }
            return missing.isEmpty ? .installed(events: ordered) : .incomplete(installed: ordered, missing: missing)
        } catch {
            return .unreadable((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func allOwnedCommands(in root: OrderedJSON) -> [String] {
        guard case let .object(events) = root["hooks"] ?? .null else { return [] }
        return events.flatMap { _, value -> [String] in
            (value.arrayValue ?? []).flatMap { group in
                (group["hooks"]?.arrayValue ?? []).compactMap { $0["command"]?.stringValue }
                    .filter { $0.contains(ClaudeCodeHookInstaller.ownedMarker) }
            }
        }
    }

    private func parseRoot(_ text: String?) throws -> OrderedJSON {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .object([]) }
        let root: OrderedJSON
        do {
            root = try OrderedJSON.parse(text)
        } catch {
            throw ConfigEditError.unreadable(String(describing: error))
        }
        guard root.objectPairs != nil else { throw ConfigEditError.notAnObject }
        return root
    }
}

/// Minimal semantic version for capability checks.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ text: String) {
        let core = text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "+" }).first ?? ""
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else { return nil }
        self.init(major: major, minor: minor, patch: parts.count > 2 ? (parts[2] ?? 0) : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
