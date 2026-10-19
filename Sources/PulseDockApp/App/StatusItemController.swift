import AppKit

/// Menu bar extra: always-available entry point (the app has no Dock icon), including a way
/// to bring the macOS Dock back.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "PulseDock")
            button.image?.isTemplate = true
            button.toolTip = "PulseDock"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    isolated deinit {
        NSStatusBar.system.removeStatusItem(item)
    }

    func refresh() {}

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let settings = services.settings.settings

        menu.addSubmenu(tr("menu.workspace", "Workspace"), symbol: "square.stack.3d.up") { submenu in
            for workspace in settings.workspaces {
                submenu.add(workspace.displayName, symbol: workspace.symbol, state: workspace.id == settings.activeWorkspace?.id ? .on : .off) { [weak self] in
                    self?.services.dockController.switchWorkspace(to: workspace.id)
                }
            }
        }
        menu.addSeparator()
        let visible = services.dockWindow.panel.isVisible
        menu.add(visible ? tr("menu.hideDock", "Hide PulseDock") : tr("menu.showDock", "Show PulseDock"), symbol: "dock.rectangle") { [weak self] in
            self?.services.toggleDockVisibility()
        }
        menu.add(tr("menu.missionControl", "AI Mission Control"), symbol: "sparkles.rectangle.stack") { [weak self] in
            self?.services.openMissionControl()
        }
        menu.add(tr("menu.settings", "Settings…"), symbol: "gearshape") { [weak self] in
            self?.services.openSettings()
        }
        menu.addSeparator()
        menu.add(tr("menu.quit", "Quit PulseDock"), symbol: "power") {
            NSApp.terminate(nil)
        }
    }
}
