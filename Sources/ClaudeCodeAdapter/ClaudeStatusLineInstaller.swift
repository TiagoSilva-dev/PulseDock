import AdapterSupport
import AgentBridge
import Foundation

/// Installs PulseDock's status line in `~/.claude/settings.json`, the official channel through
/// which Claude Code reports usage: rate-limit windows for Pro and Max (5-hour and weekly
/// percentages with reset times), the session cost estimate and context window use
/// (`code.claude.com/docs/en/statusline`). No credentials are read.
///
/// Claude Code has a single `statusLine`. If the user already has one, it keeps running: its
/// object is saved to `claude-statusline-chain.json`, the helper runs it with the same input
/// and prints its output, and it is also embedded as the shell fallback, so the user's status
/// line survives even if PulseDock is deleted without uninstalling. Removal restores the
/// original object exactly.
public struct ClaudeStatusLineInstaller: Sendable {
    public static let key = "statusLine"

    public var settingsURL: URL
    public var helperPath: String
    public var backupsDirectory: URL
    public var chainURL: URL

    public init(
        settingsURL: URL = ClaudeCodeDetector.defaultSettingsURL,
        helperPath: String = BridgePaths.installedHelper.path,
        backupsDirectory: URL = BridgePaths.backupsDirectory,
        chainURL: URL = BridgePaths.statusLineChain
    ) {
        self.settingsURL = settingsURL
        self.helperPath = helperPath
        self.backupsDirectory = backupsDirectory
        self.chainURL = chainURL
    }

    public struct Plan: Sendable, Equatable {
        public var change: ConfigChangePlan
        /// Install: the user's own status line object (JSON) kept behind PulseDock's.
        public var chained: String?
        public var isUninstall: Bool
    }

    public enum Status: Equatable, Sendable {
        /// `hasOwn`: the user has a status line of their own (it would be kept).
        case notInstalled(hasOwn: Bool)
        case installed(chained: Bool)
        /// PulseDock's status line points to another helper path.
        case outdated
        case unreadable(String)
    }

    static let fallbackOpen = " || ( "
    static let fallbackClose = "\n)"

    public func command(fallback: String?) -> String {
        let quoted = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let head = "[ -x \(quoted) ] && exec \(quoted) claude-statusline"
        guard let fallback, !fallback.isEmpty else { return head + " || exit 0" }
        // The newline before ")" keeps a trailing comment in the user's command harmless.
        return head + Self.fallbackOpen + fallback + Self.fallbackClose
    }

    static func isOwned(_ statusLine: OrderedJSON?) -> Bool {
        statusLine?["command"]?.stringValue?.contains(ClaudeCodeHookInstaller.ownedMarker) == true
    }

    /// The user's command embedded as fallback in an installed PulseDock command.
    static func embeddedFallback(in command: String) -> String? {
        guard let open = command.range(of: fallbackOpen), command.hasSuffix(fallbackClose) else { return nil }
        let inner = command[open.upperBound..<command.index(command.endIndex, offsetBy: -fallbackClose.count)]
        return inner.isEmpty ? nil : String(inner)
    }

    /// The original object saved at install time, if still present.
    func savedChain() -> OrderedJSON? {
        guard let text = try? ConfigFileIO.read(chainURL), let value = try? OrderedJSON.parse(text), value.objectPairs != nil else { return nil }
        return value
    }

    // MARK: Plans

    public func planInstall() throws -> Plan {
        let original = try ConfigFileIO.read(settingsURL)
        let root = try parseRoot(original)
        let existing = root[Self.key]
        var own: OrderedJSON?
        if Self.isOwned(existing) {
            own = savedChain() ?? existing?["command"]?.stringValue.flatMap(Self.embeddedFallback).map { .object([("type", .string("command")), ("command", .string($0))]) }
        } else if let existing, existing["command"]?.stringValue?.isEmpty == false {
            own = existing
        }
        var object: OrderedJSON = .object([("type", .string("command"))])
        if let own, case let .object(pairs) = own {
            // Keep the user's padding, refreshInterval and other options.
            object = .object(pairs.filter { $0.0 != "command" })
        }
        object = object.setting("command", to: .string(command(fallback: own?["command"]?.stringValue)))
        let newRoot = root.setting(Self.key, to: object)
        return Plan(
            change: ConfigChangePlan(
                fileURL: settingsURL,
                originalText: original,
                newText: newRoot == root ? (original ?? "") : newRoot.serialized(),
                addedEvents: [Self.key],
                removedHandlers: Self.isOwned(existing) ? 1 : 0,
                preservedForeignHandlers: own == nil ? 0 : 1
            ),
            chained: own.map { $0.serialized() },
            isUninstall: false
        )
    }

    public func planUninstall() throws -> Plan {
        let original = try ConfigFileIO.read(settingsURL)
        let root = try parseRoot(original)
        let existing = root[Self.key]
        guard Self.isOwned(existing) else {
            return Plan(change: ConfigChangePlan(fileURL: settingsURL, originalText: original, newText: original ?? "", addedEvents: [], removedHandlers: 0, preservedForeignHandlers: 0),
                        chained: nil, isUninstall: true)
        }
        var restored: OrderedJSON?
        if let saved = savedChain() {
            restored = saved
        } else if let fallback = existing?["command"]?.stringValue.flatMap(Self.embeddedFallback), case let .object(pairs)? = existing {
            restored = .object(pairs.filter { $0.0 != "command" }).setting("command", to: .string(fallback))
        }
        let newRoot = restored.map { root.setting(Self.key, to: $0) } ?? root.removing(Self.key)
        return Plan(
            change: ConfigChangePlan(fileURL: settingsURL, originalText: original, newText: newRoot.serialized(), addedEvents: [],
                                     removedHandlers: 1, preservedForeignHandlers: restored == nil ? 0 : 1),
            chained: nil,
            isUninstall: true
        )
    }

    /// Applies a reviewed plan. Returns the backup location (if a file existed).
    @discardableResult
    public func apply(_ plan: Plan) throws -> URL? {
        guard !plan.change.isNoOp else { return nil }
        let current = try ConfigFileIO.read(plan.change.fileURL)
        guard current == plan.change.originalText else { throw ConfigEditError.changedSinceReview }
        let backup = try ConfigFileIO.backup(plan.change.fileURL, into: backupsDirectory, prefix: "claude-settings")
        if !plan.isUninstall {
            // The chain must exist before Claude Code runs the new command.
            if let chained = plan.chained {
                try FileManager.default.createDirectory(at: chainURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ConfigFileIO.writeAtomically(chained, to: chainURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: chainURL.path)
            } else {
                try? FileManager.default.removeItem(at: chainURL)
            }
        }
        try ConfigFileIO.writeAtomically(plan.change.newText, to: plan.change.fileURL)
        let written = try ConfigFileIO.read(plan.change.fileURL) ?? ""
        let root: OrderedJSON
        do {
            root = try OrderedJSON.parse(written)
        } catch {
            throw ConfigEditError.validationFailed(String(describing: error))
        }
        guard Self.isOwned(root[Self.key]) != plan.isUninstall else {
            throw ConfigEditError.validationFailed("statusLine was not \(plan.isUninstall ? "removed" : "installed")")
        }
        if plan.isUninstall { try? FileManager.default.removeItem(at: chainURL) }
        return backup
    }

    // MARK: Status

    public func status() -> Status {
        do {
            let root = try parseRoot(try ConfigFileIO.read(settingsURL))
            let existing = root[Self.key]
            guard Self.isOwned(existing) else {
                return .notInstalled(hasOwn: existing?["command"]?.stringValue?.isEmpty == false)
            }
            guard existing?["command"]?.stringValue?.contains(helperPath) == true else { return .outdated }
            let chained = savedChain() != nil || existing?["command"]?.stringValue.flatMap(Self.embeddedFallback) != nil
            return .installed(chained: chained)
        } catch {
            return .unreadable((error as? LocalizedError)?.errorDescription ?? String(describing: error))
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
