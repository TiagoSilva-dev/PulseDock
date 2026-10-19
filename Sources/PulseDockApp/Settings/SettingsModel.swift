import AdapterSupport
import AgentBridge
import AgentCore
import AppKit
import ClaudeCodeAdapter
import CodexAdapter
import Diagnostics
import DockCore
import Foundation
import Observation
import Persistence
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

/// Actions behind the Settings window. Anything with effects outside PulseDock goes through
/// an explicit confirmation step (preview sheet or alert) before it runs.
@Observable
final class SettingsModel {
    var selection: SettingsPane = .general
    var installSheet: InstallSheet?
    var lastMessage: String?
    var loginItemState = LoginItem.state
    var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    var databaseStatistics: PersistenceController.Statistics?
    var selfTestResult: Bool?
    var managedTaskSheetVisible = false

    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored lazy var replacement = ReplacementModeController(settings: services.settings)

    init(services: AppServices) {
        self.services = services
    }

    var settings: SettingsStore { services.settings }
    var integrations: IntegrationsManager { services.integrations }

    /// A reviewed configuration change waiting for consent.
    struct InstallSheet: Identifiable {
        enum Target {
            case claudeInstall
            case claudeUninstall
            case codexHooksInstall
            case codexHooksUninstall
            case codexNotifyInstall(CodexNotifyInstaller.Plan)
            case claudeStatusLineInstall(ClaudeStatusLineInstaller.Plan)
            case claudeStatusLineUninstall(ClaudeStatusLineInstaller.Plan)
        }

        let id = UUID()
        var target: Target
        var plan: ConfigChangePlan
        var title: String
        var explanation: [String]
        var error: String?
        var backupLocation: URL?
        var done = false
    }

    // MARK: Integrations

    func prepare(_ target: InstallSheet.Target) {
        do {
            let plan: ConfigChangePlan
            let title: String
            var explanation: [String]
            switch target {
            case .claudeInstall:
                plan = try integrations.planClaudeInstall()
                title = tr("install.claude.title", "Connect Claude Code")
                explanation = [
                    tr("install.claude.what", "Adds PulseDock hooks to your user settings (~/.claude/settings.json), so every project is covered."),
                    tr("install.claude.events", "Observed events: sessions, prompts (not their text), tool calls, permission requests, notifications, subagents, tasks and turn endings."),
                    tr("install.claude.privacy", "The hook helper removes prompts, file contents, command output and assistant messages before anything reaches PulseDock."),
                    tr("install.claude.safety", "Your existing hooks are kept. A backup is saved first, and uninstalling removes only PulseDock entries."),
                ]
            case .claudeUninstall:
                plan = try integrations.planClaudeUninstall()
                title = tr("install.claude.uninstall.title", "Disconnect Claude Code")
                explanation = [tr("install.uninstall.what", "Removes only the hooks PulseDock added. Everything else in the file stays as it is.")]
            case .codexHooksInstall:
                plan = try integrations.planCodexHooksInstall()
                title = tr("install.codex.title", "Connect Codex (hooks)")
                explanation = [
                    tr("install.codex.what", "Adds PulseDock hooks to ~/.codex/hooks.json."),
                    tr("install.codex.trust", "Codex runs new hooks only after you review and trust them: open Codex and run /hooks once after installing."),
                    tr("install.codex.events", "Observed events: sessions, prompts (not their text), tool calls, approval requests, subagents, interrupts and turn endings."),
                ]
            case .codexHooksUninstall:
                plan = try integrations.planCodexHooksUninstall()
                title = tr("install.codex.uninstall.title", "Disconnect Codex hooks")
                explanation = [tr("install.uninstall.what", "Removes only the hooks PulseDock added. Everything else in the file stays as it is.")]
            case let .codexNotifyInstall(notifyPlan):
                plan = notifyPlan.change
                title = tr("install.notify.title", "Codex notifications (turn end only)")
                explanation = [
                    tr("install.notify.what", "Sets notify in ~/.codex/config.toml. Codex only reports the end of each turn this way; PulseDock will not show activity in between."),
                ]
                if let previous = notifyPlan.previousCommand {
                    explanation.append(tr("install.notify.chain", "Your current notify command (%@) keeps working: PulseDock forwards every notification to it.", previous.joined(separator: " ")))
                }
            case let .claudeStatusLineInstall(statusPlan):
                plan = statusPlan.change
                title = tr("install.statusLine.title", "Show Claude usage in PulseDock")
                explanation = [
                    tr("install.statusLine.what", "Sets PulseDock's status line in ~/.claude/settings.json. It is the official way Claude Code shares usage: your 5-hour and weekly limits (Pro and Max), the session cost estimate and context use."),
                    tr("install.statusLine.privacy", "Only those numbers, the model and the project folder reach PulseDock. Credentials, prompts and session titles are never read."),
                    statusPlan.chained == nil
                        ? tr("install.statusLine.new", "Claude Code will show a compact line under the prompt (model, context, 5h and 7d use). With a status line, Claude Code hides most footer key hints.")
                        : tr("install.statusLine.chain", "Your current status line keeps working: PulseDock runs it with the same data and shows its output. Disconnecting puts it back exactly."),
                ]
            case let .claudeStatusLineUninstall(statusPlan):
                plan = statusPlan.change
                title = tr("install.statusLine.uninstall.title", "Stop showing Claude usage")
                explanation = [tr("install.statusLine.uninstall.what", "Removes PulseDock's status line and restores the one you had before, if any.")]
            }
            installSheet = InstallSheet(target: target, plan: plan, title: title, explanation: explanation)
        } catch {
            lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Claude Usage: plans the status line change and opens the review sheet.
    func prepareStatusLine(install: Bool) {
        do {
            prepare(install ? .claudeStatusLineInstall(try integrations.planStatusLineInstall()) : .claudeStatusLineUninstall(try integrations.planStatusLineUninstall()))
        } catch {
            lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func prepareCodexNotify() {
        do {
            prepare(.codexNotifyInstall(try integrations.planCodexNotifyInstall()))
        } catch {
            lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func confirmInstallSheet() {
        guard var sheet = installSheet else { return }
        Task { @MainActor in
            do {
                switch sheet.target {
                case .claudeInstall, .claudeUninstall:
                    sheet.backupLocation = try await integrations.applyClaude(sheet.plan)
                case .codexHooksInstall, .codexHooksUninstall:
                    sheet.backupLocation = try await integrations.applyCodexHooks(sheet.plan)
                case let .codexNotifyInstall(plan):
                    try await integrations.applyCodexNotify(plan)
                case let .claudeStatusLineInstall(plan), let .claudeStatusLineUninstall(plan):
                    sheet.backupLocation = try await integrations.applyStatusLine(plan)
                }
                sheet.done = true
                sheet.error = nil
            } catch {
                sheet.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            installSheet = sheet
        }
    }

    func runSelfTest() {
        selfTestResult = nil
        Task { @MainActor in
            selfTestResult = await services.bridge.runSelfTest()
        }
    }

    // MARK: General

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            lastMessage = error.localizedDescription
        }
        loginItemState = LoginItem.state
    }

    func setOperatingMode(_ mode: OperatingMode, delay: Bool = false) {
        do {
            switch mode {
            case .replacement: try replacement.enable(delay ? .autoHideWithDelay : .autoHide)
            case .companion: try replacement.restore()
            }
        } catch SystemDockController.ControlError.automationDenied {
            lastMessage = tr("replacement.denied", "macOS did not allow PulseDock to change the Dock. Allow it in System Settings › Privacy & Security › Automation › PulseDock › System Events.")
        } catch {
            lastMessage = error.localizedDescription
        }
        services.dockWindow.reposition()
    }

    func confirmReplacementMode() {
        let alert = NSAlert()
        alert.messageText = tr("replacement.confirm.title", "Use PulseDock as your main dock?")
        alert.informativeText = tr("replacement.confirm.body", "PulseDock will turn on “Automatically hide and show the Dock” for the macOS Dock, using System Events. The macOS Dock is not removed: it still appears when you move the pointer to the screen edge, and you can restore it at any time from the menu bar or Settings.")
        alert.addButton(withTitle: tr("replacement.confirm.ok", "Hide the macOS Dock"))
        alert.addButton(withTitle: tr("common.cancel", "Cancel"))
        let delay = NSButton(checkboxWithTitle: tr("replacement.confirm.delay", "Also delay its reveal (one Dock restart)"), target: nil, action: nil)
        alert.accessoryView = delay
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setOperatingMode(.replacement, delay: delay.state == .on)
    }

    // MARK: Notifications

    func refreshNotificationAuthorization() {
        guard NotificationCoordinator.isAvailable else { return }
        Task { @MainActor in
            notificationAuthorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    func sendTestNotification() {
        guard NotificationCoordinator.isAvailable else {
            lastMessage = tr("notifications.unavailable", "Notifications are only available when PulseDock runs as an app bundle.")
            return
        }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                refreshNotificationAuthorization()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "PulseDock"
            content.body = tr("notifications.test.body", "Notifications are working. Approvals and failures will look like this.")
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "pulsedock.test", content: content, trigger: nil))
            refreshNotificationAuthorization()
        }
    }

    // MARK: Privacy and data

    func refreshStatistics() {
        Task { @MainActor in databaseStatistics = await services.persistence?.statistics() }
    }

    func deleteHistory() {
        let alert = NSAlert()
        alert.messageText = tr("privacy.delete.title", "Delete all agent history?")
        alert.informativeText = tr("privacy.delete.body", "Sessions and events stored by PulseDock on this Mac will be permanently deleted. Live sessions keep updating.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("privacy.delete.confirm", "Delete History"))
        alert.addButton(withTitle: tr("common.cancel", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        services.persistence?.deleteHistory { [weak self] in
            Task { @MainActor in self?.refreshStatistics() }
        }
    }

    // MARK: Advanced

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PulseDock-diagnostics-\(Int(Date().timeIntervalSince1970)).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = DiagnosticsReport.make(services: services)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: url, options: .atomic)
            lastMessage = tr("advanced.export.done", "Diagnostics exported. The file contains no prompts, paths or command text.")
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func resetSettings() {
        let alert = NSAlert()
        alert.messageText = tr("advanced.reset.title", "Reset all settings?")
        alert.informativeText = tr("advanced.reset.body", "Workspaces are rebuilt from your macOS Dock and every preference returns to its default. Agent history and installed hooks are not affected.")
        alert.addButton(withTitle: tr("advanced.reset.confirm", "Reset"))
        alert.addButton(withTitle: tr("common.cancel", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.resetToDefaults()
        services.dockModel.rebuild()
    }

    func removeAllHooks() {
        let alert = NSAlert()
        alert.messageText = tr("advanced.unhook.title", "Remove every PulseDock hook?")
        alert.informativeText = tr("advanced.unhook.body", "PulseDock entries are removed from Claude Code and Codex configuration (backups are saved first). Other hooks are kept.")
        alert.addButton(withTitle: tr("advanced.unhook.confirm", "Remove Hooks"))
        alert.addButton(withTitle: tr("common.cancel", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            let errors = await integrations.uninstallEverything()
            lastMessage = errors.isEmpty ? tr("advanced.unhook.done", "All PulseDock hooks were removed.") : errors.joined(separator: "\n")
        }
    }

    func restoreSystemDock() {
        do {
            try replacement.restore()
            lastMessage = tr("advanced.restore.done", "The macOS Dock was restored to its previous settings.")
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func openDataFolder() {
        NSWorkspace.shared.open(BridgePaths.supportDirectory)
    }
}

/// Sanitized diagnostics export: versions, counters, statuses and developer messages only.
struct DiagnosticsReport: Codable {
    var generatedAt: Date
    var appVersion: String
    var macOS: String
    var bridge: String
    var helperDeployed: Bool
    var counters: [String: Int]
    var lastEvents: [String: Date]
    var memoryFootprint: UInt64?
    var cpuTimeSeconds: Double
    var sessions: Int
    var integrations: [String: String]
    var entries: [DiagnosticsRecorder.Entry]

    @MainActor
    static func make(services: AppServices) -> DiagnosticsReport {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let integrations = services.integrations
        return DiagnosticsReport(
            generatedAt: Date(),
            appVersion: version,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            bridge: String(describing: services.bridge.status),
            helperDeployed: services.bridge.helperInstalled,
            counters: DiagnosticsRecorder.shared.allCounters,
            lastEvents: Dictionary(uniqueKeysWithValues: services.agents.lastEventAt.map { ($0.key.rawValue, $0.value) }),
            memoryFootprint: ProcessMetrics.physicalFootprint(),
            cpuTimeSeconds: ProcessMetrics.cpuTime(),
            sessions: services.agents.engine.sessions.count,
            integrations: [
                "claude_version": integrations.claude?.version ?? "not found",
                "claude_hooks": String(describing: integrations.claudeStatus),
                "codex_version": integrations.codex?.version ?? "not found",
                "codex_hook_events": "\(integrations.codexHookEvents.count)",
                "codex_notify": integrations.codexNotifyInstalled ? "installed" : "not installed",
            ],
            entries: DiagnosticsRecorder.shared.entries
        )
    }
}
