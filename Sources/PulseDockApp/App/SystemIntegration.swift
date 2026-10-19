import AppKit
import Diagnostics
import DockCore
import ServiceManagement

/// Launch at login through `SMAppService` (the user can also manage it in System Settings).
enum LoginItem {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Replacement Mode: the macOS Dock is set to auto-hide (documented System Events
/// scripting), with the original configuration recorded first so it can be restored. It
/// never removes or disables the Dock, never touches SIP and never kills it repeatedly; the
/// Dock stays reachable at the screen edge even if PulseDock quits unexpectedly.
final class ReplacementModeController {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    enum Change {
        /// Auto-hide the macOS Dock.
        case autoHide
        /// Also make the macOS Dock wait longer before revealing (one Dock relaunch).
        case autoHideWithDelay
    }

    func enable(_ change: Change) throws {
        let current = SystemDockPreferences.current()
        if settings.settings.systemDockRestorePoint == nil {
            settings.update {
                $0.systemDockRestorePoint = SystemDockRestorePoint(autohide: current.autohide, autohideDelay: current.autohideDelay, changedDelay: false)
            }
        }
        try SystemDockController.setAutohide(true)
        if change == .autoHideWithDelay {
            try SystemDockController.setAutohideDelay(1.5)
            settings.update { $0.systemDockRestorePoint?.changedDelay = true }
        }
        settings.update { $0.general.operatingMode = .replacement }
        PulseLog.dock.info("Replacement Mode enabled")
    }

    /// Restores the macOS Dock exactly as it was before Replacement Mode.
    func restore() throws {
        guard let point = settings.settings.systemDockRestorePoint else {
            settings.update { $0.general.operatingMode = .companion }
            return
        }
        try SystemDockController.setAutohide(point.autohide)
        if point.changedDelay {
            try SystemDockController.setAutohideDelay(point.autohideDelay)
        }
        settings.update {
            $0.systemDockRestorePoint = nil
            $0.general.operatingMode = .companion
        }
        PulseLog.dock.info("macOS Dock restored")
    }

    var hasRestorePoint: Bool { settings.settings.systemDockRestorePoint != nil }
}

/// Minimal main menu, shown while a PulseDock window is open.
enum MainMenu {
    static func install(openSettings: @escaping @MainActor () -> Void, openMissionControl: @escaping @MainActor () -> Void) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.add(tr("mainmenu.about", "About PulseDock")) { NSApp.orderFrontStandardAboutPanel(nil) }
        appMenu.addSeparator()
        let settingsItem = ClosureMenuItem(tr("mainmenu.settings", "Settings…"), key: ",", modifiers: .command, handler: openSettings)
        appMenu.addItem(settingsItem)
        let missionItem = ClosureMenuItem(tr("mainmenu.missionControl", "AI Mission Control"), key: "m", modifiers: [.command, .shift], handler: openMissionControl)
        appMenu.addItem(missionItem)
        appMenu.addSeparator()
        appMenu.addItem(NSMenuItem(title: tr("mainmenu.hide", "Hide PulseDock"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: tr("mainmenu.quit", "Quit PulseDock"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr("mainmenu.edit", "Edit"))
        editMenu.addItem(NSMenuItem(title: tr("mainmenu.undo", "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: tr("mainmenu.redo", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: tr("mainmenu.cut", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: tr("mainmenu.copy", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: tr("mainmenu.paste", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: tr("mainmenu.selectAll", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: tr("mainmenu.window", "Window"))
        windowMenu.addItem(NSMenuItem(title: tr("mainmenu.minimize", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: tr("mainmenu.close", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
