import AdapterSupport
import AgentBridge
import AgentCore
import ClaudeCodeAdapter
import CodexAdapter
import Foundation
import Observation

/// Detection, status and (consented) installation of the agent integrations.
@Observable
final class IntegrationsManager {
    enum ConnectionState: Equatable {
        /// The agent CLI was not found on this Mac.
        case agentNotFound
        /// Found, but PulseDock's hooks are not installed.
        case notConnected
        /// Hooks installed; no event received yet in this run.
        case waitingForFirstEvent
        /// Codex: hooks installed, waiting for the user to trust them with `/hooks`.
        case awaitingTrust
        case receiving(Date)
        case needsAttention(String)
    }

    private(set) var claude: ClaudeCodeInstallation?
    private(set) var claudeStatus: ClaudeCodeHookInstaller.Status = .notInstalled
    /// PulseDock's status line (the source of the Claude Usage widget).
    private(set) var claudeStatusLine: ClaudeStatusLineInstaller.Status = .notInstalled(hasOwn: false)
    private(set) var codex: CodexInstallation?
    private(set) var codexHookEvents: [String] = []
    private(set) var codexNotifyInstalled = false
    private(set) var isRefreshing = false

    @ObservationIgnored let bridge: AgentBridgeService
    @ObservationIgnored private let store: AgentStore

    init(bridge: AgentBridgeService, store: AgentStore) {
        self.bridge = bridge
        self.store = store
    }

    var claudeInstaller: ClaudeCodeHookInstaller {
        ClaudeCodeHookInstaller(settingsURL: claude?.settingsURL ?? ClaudeCodeDetector.defaultSettingsURL)
    }

    var statusLineInstaller: ClaudeStatusLineInstaller {
        ClaudeStatusLineInstaller(settingsURL: claude?.settingsURL ?? ClaudeCodeDetector.defaultSettingsURL)
    }

    var codexHookInstaller: CodexHookInstaller {
        CodexHookInstaller(hooksURL: (codex?.homeDirectory ?? CodexDetector.homeDirectory).appendingPathComponent("hooks.json"))
    }

    var codexNotifyInstaller: CodexNotifyInstaller {
        CodexNotifyInstaller(configURL: (codex?.homeDirectory ?? CodexDetector.homeDirectory).appendingPathComponent("config.toml"))
    }

    /// Detection runs off the main thread (it may run `claude --version`).
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let (claude, codex) = await Task.detached(priority: .utility) {
            (ClaudeCodeDetector.detect(), CodexDetector.detect())
        }.value
        self.claude = claude
        self.codex = codex
        claudeStatus = claudeInstaller.status(version: claude.version)
        claudeStatusLine = statusLineInstaller.status()
        codexHookEvents = codexHookInstaller.installedEvents()
        codexNotifyInstalled = codexNotifyInstaller.isInstalled()
    }

    func connectionState(for provider: AgentProvider) -> ConnectionState {
        let lastEvent = store.lastEventAt[provider]
        switch provider {
        case .claudeCode:
            guard claude?.isInstalled == true || lastEvent != nil else { return .agentNotFound }
            switch claudeStatus {
            case .notInstalled: return lastEvent.map(ConnectionState.receiving) ?? .notConnected
            case .installed: return lastEvent.map(ConnectionState.receiving) ?? .waitingForFirstEvent
            case .incomplete: return .needsAttention(tr("integration.status.incomplete", "Some hooks are missing — reinstall to repair."))
            case .outdated: return .needsAttention(tr("integration.status.outdated", "Hooks point to an old helper location — reinstall to update."))
            case let .unreadable(message): return .needsAttention(message)
            }
        case .codex:
            guard codex?.isInstalled == true || lastEvent != nil else { return .agentNotFound }
            if let lastEvent { return .receiving(lastEvent) }
            if !codexHookEvents.isEmpty { return .awaitingTrust }
            if codexNotifyInstalled { return .waitingForFirstEvent }
            return .notConnected
        case .demo:
            return store.isDemoRunning ? .receiving(Date()) : .notConnected
        }
    }

    // MARK: Plans and application (always after the user reviewed the preview)

    func planClaudeInstall() throws -> ConfigChangePlan {
        bridge.deployHelper()
        return try claudeInstaller.planInstall(version: claude?.version)
    }

    func planClaudeUninstall() throws -> ConfigChangePlan {
        try claudeInstaller.planUninstall()
    }

    @discardableResult
    func applyClaude(_ plan: ConfigChangePlan) async throws -> URL? {
        let backup = try claudeInstaller.apply(plan)
        await refresh()
        return backup
    }

    func planStatusLineInstall() throws -> ClaudeStatusLineInstaller.Plan {
        bridge.deployHelper()
        return try statusLineInstaller.planInstall()
    }

    func planStatusLineUninstall() throws -> ClaudeStatusLineInstaller.Plan {
        try statusLineInstaller.planUninstall()
    }

    @discardableResult
    func applyStatusLine(_ plan: ClaudeStatusLineInstaller.Plan) async throws -> URL? {
        let backup = try statusLineInstaller.apply(plan)
        await refresh()
        return backup
    }

    func planCodexHooksInstall() throws -> ConfigChangePlan {
        bridge.deployHelper()
        return try codexHookInstaller.planInstall()
    }

    func planCodexHooksUninstall() throws -> ConfigChangePlan {
        try codexHookInstaller.planUninstall()
    }

    @discardableResult
    func applyCodexHooks(_ plan: ConfigChangePlan) async throws -> URL? {
        let backup = try codexHookInstaller.apply(plan)
        await refresh()
        return backup
    }

    func planCodexNotifyInstall() throws -> CodexNotifyInstaller.Plan {
        bridge.deployHelper()
        return try codexNotifyInstaller.planInstall()
    }

    func applyCodexNotify(_ plan: CodexNotifyInstaller.Plan) async throws {
        try codexNotifyInstaller.apply(plan)
        await refresh()
    }

    func uninstallCodexNotify() async throws {
        try codexNotifyInstaller.applyUninstall(codexNotifyInstaller.planUninstall())
        await refresh()
    }

    /// Removes every PulseDock hook (Settings › Advanced › restore and app removal).
    func uninstallEverything() async -> [String] {
        var errors: [String] = []
        do { try claudeInstaller.apply(try claudeInstaller.planUninstall()) } catch { errors.append("Claude Code: \(error.localizedDescription)") }
        do { try statusLineInstaller.apply(try statusLineInstaller.planUninstall()) } catch { errors.append("Claude Code status line: \(error.localizedDescription)") }
        do { try codexHookInstaller.apply(try codexHookInstaller.planUninstall()) } catch { errors.append("Codex hooks: \(error.localizedDescription)") }
        if codexNotifyInstalled {
            do { try await uninstallCodexNotify() } catch { errors.append("Codex notify: \(error.localizedDescription)") }
        }
        await refresh()
        return errors
    }
}
