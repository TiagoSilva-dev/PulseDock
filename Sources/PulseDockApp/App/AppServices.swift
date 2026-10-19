import AgentBridge
import AgentCore
import AppKit
import Diagnostics
import DockCore
import DockRendering
import Persistence
import SwiftUI

/// Composition root: creates every service once and wires them together.
final class AppServices {
    let persistence: PersistenceController?
    let settings: SettingsStore
    let accessibility = AccessibilityOptions()
    let runningApps = RunningApplicationsMonitor()
    let dockModel: DockModel
    let accessories = DockAccessories()
    let dockWindow: DockWindowController
    let dockController: DockController
    let agents: AgentStore
    let bridge: AgentBridgeService
    let integrations: IntegrationsManager
    let managedCodex: CodexManagedService
    let notifications: NotificationCoordinator
    let agentUI: AgentUIController
    let widgets: WidgetController
    let arguments: [String]
    private var systemObservers: [NSObjectProtocol] = []
    private(set) var statusItem: StatusItemController?
    private(set) lazy var windows = WindowCoordinator(services: self)

    var isDeveloperMode: Bool { arguments.contains("--developer") }

    init(persistence: PersistenceController?, arguments: [String]) {
        self.persistence = persistence
        self.arguments = arguments
        settings = SettingsStore(persistence: persistence)
        dockModel = DockModel(settings: settings, runningApps: runningApps, accessibility: accessibility)
        let root = DockRootView(model: dockModel, accessories: accessories)
        dockWindow = DockWindowController(model: dockModel, settings: settings, content: root)
        dockController = DockController(model: dockModel, windowController: dockWindow, settings: settings, runningApps: runningApps)
        agents = AgentStore(persistence: persistence, settings: settings)
        bridge = AgentBridgeService(store: agents)
        integrations = IntegrationsManager(bridge: bridge, store: agents)
        managedCodex = CodexManagedService(store: agents)
        notifications = NotificationCoordinator(settings: settings, store: agents)
        agentUI = AgentUIController(store: agents, settings: settings, integrations: integrations, managed: managedCodex,
                                    accessibility: accessibility, dockWindow: dockWindow)
        widgets = WidgetController(settings: settings, agents: agents, persistence: persistence, accessibility: accessibility, dockWindow: dockWindow)
    }

    func start() {
        accessibility.forceLegacyMaterial = settings.settings.advanced.forceLegacyMaterial
        wireDock()
        wireAgents()

        dockWindow.show()
        if settings.settings.general.showMenuBarItem {
            statusItem = StatusItemController(services: self)
        }
        HotKeys.shared.register(.togglePrivacy) { [weak self] in self?.settings.update { $0.privacy.privacyMode.toggle() } }
        HotKeys.shared.register(.nextWorkspace) { [weak self] in self?.cycleWorkspace() }
        observeSleepAndWake()

        Task { @MainActor in
            await agents.restore()
            bridge.start(useRegistry: settings.settings.agents.useSessionRegistry)
            agents.start()
            await integrations.refresh()
            if arguments.contains("--demo") || settings.settings.advanced.demoMode {
                agents.setDemo(true)
            }
            if !settings.settings.hasCompletedOnboarding, !arguments.contains("--no-onboarding") {
                windows.showOnboarding()
            }
        }
        PulseLog.app.info("PulseDock started")
    }

    /// Sleep and wake: state is written before the Mac sleeps; on wake, liveness and staleness
    /// are re-evaluated at once (a session may have ended while the Mac slept, and old
    /// "working" states must not wait for the next 30-second pass), running Claude Code
    /// sessions are rediscovered, and the dock is placed again for the current displays.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        systemObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        systemObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
        systemObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dockWindow.reposition() }
        })
    }

    func systemWillSleep() {
        widgets.claudeUsage.flush()
        widgets.data.saveNow()
        settings.flush()
        persistence?.flush()
        DiagnosticsRecorder.shared.record(.info, "system", "will sleep: state saved")
    }

    func systemDidWake() {
        agents.reconcile()
        bridge.refreshRegistry()
        dockWindow.reposition()
        DiagnosticsRecorder.shared.record(.info, "system", "did wake: sessions reconciled")
    }

    func shutdown() {
        for observer in systemObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        systemObservers.removeAll()
        managedCodex.stop()
        bridge.stop()
        widgets.cinema.stop()
        widgets.claudeUsage.flush()
        widgets.data.saveNow()
        settings.flush()
        dockWindow.tearDown()
        persistence?.flush()
    }

    // MARK: Wiring

    private func wireDock() {
        accessories.activate = { [weak self] entry in self?.dockController.dockActivate(entry, modifiers: []) }
        accessories.trashIsFull = TrashState.isFull
        accessories.island = { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(AgentPulseIslandView(store: self.agents, settings: self.settings, accessibility: self.accessibility) { [weak self] width in
                self?.dockModel.setIslandWidth(width)
            })
        }
        accessories.widget = { [weak self] placement, size in
            self?.widgets.tile(for: placement, size: size) ?? AnyView(EmptyView())
        }
        runningApps.onChange = { [weak self] in self?.dockModel.rebuild() }
        settings.observe { [weak self] old, new in self?.settingsChanged(from: old, to: new) }
        dockController.openSettings = { [weak self] in self?.openSettings() }
        dockController.openMissionControl = { [weak self] in self?.openMissionControl() }
        dockController.onIslandClick = { [weak self] anchor in self?.agentUI.toggleCard(anchor: anchor) }
        dockController.onIslandHover = { [weak self] hovering, anchor in self?.agentUI.islandHover(hovering, anchor: anchor) }
        dockController.onWidgetClick = { [weak self] placement, anchor in self?.widgets.showPanel(for: placement, anchor: anchor) }
        dockController.widgetAcceptsDrop = { [weak self] placement, pasteboard in self?.widgets.acceptsDrop(placement, pasteboard: pasteboard) ?? false }
        dockController.widgetPerformDrop = { [weak self] placement, pasteboard in self?.widgets.performDrop(placement, pasteboard: pasteboard) ?? false }
        dockController.islandMenu = { [weak self] menu in self?.agentUI.buildIslandMenu(menu) }
        widgets.openSettings = { [weak self] in self?.openSettings(pane: .appearance) }
        dockModel.showsAgentPulse = settings.settings.agents.enabled && settings.activeWorkspace.agentFilter != .hidden
    }

    private func wireAgents() {
        agents.onEvents = { [weak self] events in
            self?.notifications.handle(events)
            self?.widgets.agentEvents(events)
        }
        agents.onSummaryChange = { [weak self] summary in
            self?.widgets.agentSummaryChanged(summary)
            self?.agentUI.summaryChanged()
            self?.notifications.clearResolved()
            self?.windows.agentsChanged()
        }
        notifications.onOpenSession = { [weak self] key in self?.agentUI.openSession(key) }
        agentUI.openMissionControl = { [weak self] key in self?.openMissionControl(focus: key) }
        agentUI.openAgentSettings = { [weak self] in self?.openSettings(pane: .agents) }
        widgets.openSession = { [weak self] key in self?.agentUI.openSession(key) }
        bridge.onUsage = { [weak self] snapshot in self?.widgets.claudeUsage.ingest(snapshot) }
        widgets.claudeUsage.onAlert = { [weak self] alert in self?.notifications.postUsageAlert(alert) }
        widgets.claudeUsage.connection = { [weak self] in self?.integrations.claudeStatusLine ?? .notInstalled(hasOwn: false) }
        widgets.connectClaudeUsage = { [weak self] in
            guard let self else { return }
            self.openSettings(pane: .agents)
            self.windows.settingsModel.prepareStatusLine(install: true)
        }
        managedCodex.executablePath = { [weak self] in self?.integrations.codex?.executablePath }
        bridge.onControl = { [weak self] event, payload in
            guard let self, self.isDeveloperMode else { return }
            DeveloperTools.handle(event, payload: payload, services: self)
        }
    }

    private func settingsChanged(from old: AppSettings, to new: AppSettings) {
        if old.appearance != new.appearance || old.workspaces != new.workspaces || old.activeWorkspaceID != new.activeWorkspaceID
            || old.behavior.showTrash != new.behavior.showTrash || old.collections != new.collections {
            dockModel.showsAgentPulse = new.agents.enabled && (new.activeWorkspace?.agentFilter ?? .all) != .hidden
            dockModel.rebuild()
            widgets.updateVisibility()
        }
        if old.agents.enabled != new.agents.enabled {
            dockModel.showsAgentPulse = new.agents.enabled && (new.activeWorkspace?.agentFilter ?? .all) != .hidden
        }
        if old.appearance.iconSize != new.appearance.iconSize || old.behavior.bottomMargin != new.behavior.bottomMargin
            || old.behavior.display != new.behavior.display || old.appearance.maxMagnification != new.appearance.maxMagnification {
            dockWindow.reposition()
        }
        if old.behavior.autoHide != new.behavior.autoHide || old.behavior.avoidFullScreenApps != new.behavior.avoidFullScreenApps {
            dockWindow.applyAutoHideSetting()
        }
        if old.advanced.forceLegacyMaterial != new.advanced.forceLegacyMaterial {
            accessibility.forceLegacyMaterial = new.advanced.forceLegacyMaterial
        }
        if old.advanced.demoMode != new.advanced.demoMode {
            agents.setDemo(new.advanced.demoMode)
            if !new.advanced.demoMode { widgets.recorder.clearDemo() }
        }
        if old.agents.useSessionRegistry != new.agents.useSessionRegistry {
            bridge.setRegistry(enabled: new.agents.useSessionRegistry)
        }
        if old.privacy != new.privacy || old.agents != new.agents {
            agents.refresh()
        }
        if old.general.showMenuBarItem != new.general.showMenuBarItem {
            statusItem = new.general.showMenuBarItem ? StatusItemController(services: self) : nil
        }
    }

    // MARK: Windows and commands

    func openSettings(pane: SettingsPane = .general) {
        windows.showSettings(pane: pane)
    }

    func openMissionControl(focus key: SessionKey? = nil) {
        windows.showMissionControl(focus: key)
    }

    func toggleDockVisibility() {
        if dockWindow.panel.isVisible {
            dockWindow.panel.orderOut(nil)
            widgets.updateVisibility(dockVisible: false)
        } else {
            dockWindow.panel.orderFrontRegardless()
            widgets.updateVisibility(dockVisible: true)
        }
    }

    func cycleWorkspace() {
        let workspaces = settings.settings.workspaces
        guard !workspaces.isEmpty else { return }
        let index = workspaces.firstIndex { $0.id == settings.settings.activeWorkspace?.id } ?? 0
        dockController.switchWorkspace(to: workspaces[(index + 1) % workspaces.count].id)
    }
}

/// Whether the Trash has items. Reading `~/.Trash` can be refused by privacy protections;
/// in that case PulseDock shows the empty icon rather than guessing.
enum TrashState {
    static func isFull() -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: AppLauncher.trashURL.path)
        return contents?.contains { $0 != ".DS_Store" && $0 != ".localized" } ?? false
    }
}
