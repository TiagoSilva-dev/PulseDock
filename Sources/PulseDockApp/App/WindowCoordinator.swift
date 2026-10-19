import AgentCore
import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case dockBehavior
    case agents
    case notifications
    case privacy
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: tr("settings.pane.general", "General")
        case .appearance: tr("settings.pane.appearance", "Appearance")
        case .dockBehavior: tr("settings.pane.dockBehavior", "Dock Behavior")
        case .agents: tr("settings.pane.agents", "AI Agents")
        case .notifications: tr("settings.pane.notifications", "Notifications")
        case .privacy: tr("settings.pane.privacy", "Privacy")
        case .advanced: tr("settings.pane.advanced", "Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .dockBehavior: "dock.rectangle"
        case .agents: "sparkles"
        case .notifications: "bell.badge"
        case .privacy: "hand.raised"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

/// Owns the app's regular windows (Settings, AI Mission Control, onboarding). While any of
/// them is open, PulseDock becomes a regular app (menu bar, ⌘-Tab); afterwards it goes back
/// to being an agent app.
final class WindowCoordinator: NSObject, NSWindowDelegate {
    unowned let services: AppServices
    private var settingsWindow: NSWindow?
    private var missionControlWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private(set) lazy var settingsModel = SettingsModel(services: services)
    private(set) lazy var missionControl = MissionControlModel(services: services)

    init(services: AppServices) {
        self.services = services
        super.init()
    }

    func showSettings(pane: SettingsPane) {
        settingsModel.selection = pane
        if settingsWindow == nil {
            let view = SettingsView(model: settingsModel)
            let window = makeWindow(title: tr("settings.window.title", "PulseDock Settings"), size: CGSize(width: 820, height: 600), content: view)
            window.setFrameAutosaveName("PulseDockSettings")
            settingsWindow = window
        }
        present(settingsWindow)
        Task { await services.integrations.refresh() }
    }

    func showMissionControl(focus key: SessionKey?) {
        if let key { missionControl.focus(key) }
        if missionControlWindow == nil {
            let view = MissionControlView(model: missionControl)
            let window = makeWindow(title: tr("missionControl.title", "AI Mission Control"), size: CGSize(width: 1180, height: 740), content: view)
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified
            window.setFrameAutosaveName("PulseDockMissionControl")
            missionControlWindow = window
        }
        missionControl.reload()
        present(missionControlWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(services: services) { [weak self] in
                self?.services.settings.update { $0.hasCompletedOnboarding = true }
                self?.onboardingWindow?.close()
            }
            let window = makeWindow(title: tr("onboarding.window.title", "Welcome to PulseDock"), size: CGSize(width: 620, height: 560), content: view)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable)
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    func agentsChanged() {
        if missionControlWindow?.isVisible == true { missionControl.liveChanged() }
    }

    private func makeWindow<Content: View>(title: String, size: CGSize, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            MainMenu.install(openSettings: { [weak self] in self?.showSettings(pane: .general) },
                             openMissionControl: { [weak self] in self?.showMissionControl(focus: nil) })
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let anyVisible = [self.settingsWindow, self.missionControlWindow, self.onboardingWindow].contains { $0?.isVisible == true }
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
