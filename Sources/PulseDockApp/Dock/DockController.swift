import AppKit
import Diagnostics
import DockCore
import DockRendering
import SwiftUI
import UniformTypeIdentifiers

/// Connects dock interactions to app behaviour: launching, menus, reordering, drops.
final class DockController: DockInteractionDelegate {
    let model: DockModel
    let windowController: DockWindowController
    let settings: SettingsStore
    let runningApps: RunningApplicationsMonitor
    /// Hooks provided by the agent and widget layers.
    var onIslandClick: (CGRect) -> Void = { _ in }
    var onIslandHover: (Bool, CGRect) -> Void = { _, _ in }
    var onWidgetClick: (WidgetPlacement, CGRect) -> Void = { _, _ in }
    var widgetAcceptsDrop: (WidgetPlacement, NSPasteboard) -> Bool = { _, _ in false }
    var widgetPerformDrop: (WidgetPlacement, NSPasteboard) -> Bool = { _, _ in false }
    var islandMenu: (NSMenu) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var openMissionControl: () -> Void = {}

    init(model: DockModel, windowController: DockWindowController, settings: SettingsStore, runningApps: RunningApplicationsMonitor) {
        self.model = model
        self.windowController = windowController
        self.settings = settings
        self.runningApps = runningApps
        windowController.host.delegate = self
    }

    // MARK: Activation

    func dockActivate(_ entry: DockEntry, modifiers: NSEvent.ModifierFlags) {
        switch entry.kind {
        case let .application(_, running):
            guard let url = entry.url ?? running?.bundleURL else {
                offerRemovalOfMissing(entry)
                return
            }
            if modifiers.contains(.command) {
                AppLauncher.revealInFinder(url)
            } else if modifiers.contains(.option), let running, running.pid == runningApps.frontmostPID {
                AppLauncher.hide(pid: running.pid)
            } else {
                if running == nil { runningApps.markLaunching(path: url.path) }
                AppLauncher.openOrActivate(applicationAt: url)
            }
        case .folder:
            guard let url = entry.url else {
                offerRemovalOfMissing(entry)
                return
            }
            modifiers.contains(.command) ? AppLauncher.revealInFinder(url) : AppLauncher.open(url)
        case .trash:
            AppLauncher.openTrash()
        case .agentPulse:
            if let frame = windowController.screenFrame(ofEntry: entry.id) { onIslandClick(frame) }
        case let .widget(placement):
            if let frame = windowController.screenFrame(ofEntry: entry.id) { onWidgetClick(placement, frame) }
        case .divider, .placeholder:
            break
        }
    }

    func dockHoverChanged(_ entry: DockEntry?) {
        if let entry, entry.kind == .agentPulse, let frame = windowController.screenFrame(ofEntry: entry.id) {
            onIslandHover(true, frame)
        } else {
            onIslandHover(false, .zero)
        }
    }

    private func offerRemovalOfMissing(_ entry: DockEntry) {
        let alert = NSAlert()
        alert.messageText = tr("dock.missing.title", "“%@” could not be found", entry.title)
        alert.informativeText = tr("dock.missing.body", "The item may have been moved or deleted.")
        alert.addButton(withTitle: tr("dock.missing.remove", "Remove from Dock"))
        alert.addButton(withTitle: tr("common.cancel", "Cancel"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            dockRemove(entryID: entry.id)
        }
    }

    // MARK: Reorder, remove, drop

    func dockCommitReorder(entryID: String, toIndex index: Int) {
        guard let entry = model.displayEntries.first(where: { $0.id == entryID }) else { return }
        settings.update { settings in
            settings.updateActiveWorkspace { workspace in
                var pinned = workspace.pinned
                let existing = pinned.firstIndex { $0.id.uuidString == entryID }
                let item: PinnedItem
                if let existing {
                    item = pinned.remove(at: existing)
                } else if let running = entry.running, let url = running.bundleURL {
                    item = .application(bundleIdentifier: running.bundleIdentifier, url: url)
                } else {
                    return
                }
                // Positions past the pinned section keep (or make) the item pinned at the end.
                let reorderable = self.model.reorderableEntries.filter { $0.id != entryID }
                let pinnedBefore = reorderable.prefix(index).filter { $0.pinned != nil }.count
                pinned.insert(item, at: min(pinnedBefore, pinned.count))
                workspace.pinned = pinned
            }
        }
        model.rebuild()
    }

    func dockRemove(entryID: String) {
        settings.update { settings in
            settings.updateActiveWorkspace { workspace in
                workspace.pinned.removeAll { $0.id.uuidString == entryID }
            }
        }
        model.rebuild()
    }

    func dockWidgetAcceptsDrop(_ placement: WidgetPlacement, pasteboard: NSPasteboard) -> Bool {
        widgetAcceptsDrop(placement, pasteboard)
    }

    func dockWidgetDrop(_ placement: WidgetPlacement, pasteboard: NSPasteboard) -> Bool {
        widgetPerformDrop(placement, pasteboard)
    }

    func dockDrop(urls: [URL], onto entry: DockEntry?, insertionIndex: Int?) -> Bool {
        guard !urls.isEmpty else { return false }
        switch entry?.kind {
        case .trash?:
            AppLauncher.moveToTrash(urls)
            return true
        case .application?:
            guard let appURL = entry?.url else { return false }
            AppLauncher.open(urls, withApplicationAt: appURL)
            return true
        default:
            let items: [PinnedItem] = urls.compactMap { url in
                if url.pathExtension == "app" {
                    return .application(bundleIdentifier: Bundle(url: url)?.bundleIdentifier, url: url)
                }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folder(url) }
                return nil
            }
            guard !items.isEmpty else { return false }
            pin(items, at: insertionIndex)
            return true
        }
    }

    func pin(_ items: [PinnedItem], at index: Int?) {
        settings.update { settings in
            settings.updateActiveWorkspace { workspace in
                let fresh = items.filter { item in
                    !workspace.pinned.contains { existing in
                        existing.kind == item.kind || (item.bundleIdentifier != nil && existing.bundleIdentifier == item.bundleIdentifier)
                    }
                }
                let position = min(index ?? workspace.pinned.count, workspace.pinned.count)
                workspace.pinned.insert(contentsOf: fresh, at: position)
            }
        }
        model.rebuild()
    }

    func isPinned(_ entry: DockEntry) -> Bool { entry.pinned != nil }

    // MARK: Menus

    func dockShowMenu(for entry: DockEntry?, event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let entry {
            switch entry.kind {
            case .application: buildApplicationMenu(menu, entry: entry)
            case .folder: buildFolderMenu(menu, entry: entry)
            case .trash: buildTrashMenu(menu)
            case .agentPulse: islandMenu(menu)
            case let .widget(placement): buildWidgetMenu(menu, placement: placement, entry: entry)
            case .divider, .placeholder: buildDockMenu(menu)
            }
        } else {
            buildDockMenu(menu)
        }
        windowController.isPresentingAuxiliaryUI = true
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        windowController.isPresentingAuxiliaryUI = false
    }

    private func buildApplicationMenu(_ menu: NSMenu, entry: DockEntry) {
        let running = entry.running
        if let running {
            if let windows = WindowInventory.windows(pid: running.pid) {
                for window in windows.prefix(12) where !window.title.isEmpty {
                    let item = menu.add(window.title, symbol: window.isMinimized ? "minus.rectangle" : "macwindow") {
                        WindowInventory.focus(window, pid: running.pid)
                    }
                    item.toolTip = window.isMinimized ? tr("dock.menu.minimized", "Minimized") : nil
                }
                if !windows.isEmpty { menu.addSeparator() }
            } else {
                let count = WindowInventory.onScreenWindowCount(pid: running.pid)
                if count > 0 {
                    menu.add(trp("dock.menu.windowCount", one: "%ld window on screen", other: "%ld windows on screen", count), enabled: false) {}
                }
                menu.add(tr("dock.menu.enableWindowList", "Show Window Titles…"), symbol: "lock.open") { [weak self] in
                    self?.explainAccessibility()
                }
                menu.addSeparator()
            }
        } else {
            menu.add(tr("dock.menu.open", "Open"), symbol: "arrow.up.forward.app") { [weak self] in
                self?.dockActivate(entry, modifiers: [])
            }
        }

        if entry.pinned != nil {
            menu.add(tr("dock.menu.removeFromDock", "Remove from Dock"), symbol: "pin.slash") { [weak self] in
                self?.dockRemove(entryID: entry.id)
            }
        } else if let running, let url = running.bundleURL {
            menu.add(tr("dock.menu.keepInDock", "Keep in Dock"), symbol: "pin") { [weak self] in
                self?.pin([.application(bundleIdentifier: running.bundleIdentifier, url: url)], at: nil)
            }
        }
        if let url = entry.url {
            menu.add(tr("dock.menu.showInFinder", "Show in Finder"), symbol: "folder") { AppLauncher.revealInFinder(url) }
            if let info = ApplicationInfo.load(url: url), info.allowsMultipleInstances, running != nil {
                menu.add(tr("dock.menu.newInstance", "Open New Instance"), symbol: "plus.square.on.square") {
                    AppLauncher.openOrActivate(applicationAt: url, newInstance: true)
                }
            }
        }

        if let running {
            menu.addSeparator()
            if running.isHidden {
                menu.add(tr("dock.menu.show", "Show"), symbol: "eye") { AppLauncher.unhide(pid: running.pid) }
            } else {
                menu.add(tr("dock.menu.hide", "Hide"), symbol: "eye.slash") { AppLauncher.hide(pid: running.pid) }
            }
            menu.add(tr("dock.menu.hideOthers", "Hide Others")) { AppLauncher.hideOthers(except: running.pid) }
            menu.addSeparator()
            let quit = menu.add(tr("dock.menu.quit", "Quit"), symbol: "xmark.circle") { AppLauncher.quit(pid: running.pid) }
            quit.isEnabled = running.bundleIdentifier != "com.apple.finder"
            let force = ClosureMenuItem(tr("dock.menu.forceQuit", "Force Quit"), symbol: "exclamationmark.octagon") {
                AppLauncher.forceQuit(pid: running.pid)
            }
            force.isAlternate = true
            force.keyEquivalentModifierMask = .option
            menu.addItem(force)
        }
    }

    private func buildFolderMenu(_ menu: NSMenu, entry: DockEntry) {
        if let url = entry.url {
            menu.add(tr("dock.menu.open", "Open"), symbol: "folder") { AppLauncher.open(url) }
            menu.add(tr("dock.menu.showInFinder", "Show in Finder"), symbol: "magnifyingglass") { AppLauncher.revealInFinder(url) }
            menu.addSeparator()
        }
        menu.add(tr("dock.menu.removeFromDock", "Remove from Dock"), symbol: "pin.slash") { [weak self] in
            self?.dockRemove(entryID: entry.id)
        }
    }

    private func buildTrashMenu(_ menu: NSMenu) {
        menu.add(tr("dock.menu.openTrash", "Open Trash"), symbol: "trash") { AppLauncher.openTrash() }
        menu.add(tr("dock.menu.emptyTrash", "Empty Trash…"), symbol: "trash.slash") { [weak self] in self?.confirmEmptyTrash() }
    }

    private func buildWidgetMenu(_ menu: NSMenu, placement: WidgetPlacement, entry: DockEntry) {
        menu.add(tr("dock.menu.openWidget", "Open %@", entry.title)) { [weak self] in self?.dockActivate(entry, modifiers: []) }
        menu.addSeparator()
        menu.add(tr("dock.menu.removeWidget", "Remove Widget"), symbol: "minus.circle") { [weak self] in
            self?.settings.update { settings in
                settings.updateActiveWorkspace { $0.widgets.removeAll { $0.id == placement.id } }
            }
            self?.model.rebuild()
        }
    }

    func buildDockMenu(_ menu: NSMenu) {
        let current = settings.settings
        menu.addSubmenu(tr("dock.menu.workspace", "Workspace"), symbol: "square.stack.3d.up") { submenu in
            for workspace in current.workspaces {
                submenu.add(workspace.displayName, symbol: workspace.symbol, state: workspace.id == current.activeWorkspace?.id ? .on : .off) { [weak self] in
                    self?.switchWorkspace(to: workspace.id)
                }
            }
        }
        menu.addSubmenu(tr("dock.menu.theme", "Theme"), symbol: "paintbrush") { submenu in
            for theme in ThemeID.allCases {
                submenu.add(theme.displayName, state: current.appearance.theme == theme ? .on : .off) { [weak self] in
                    self?.settings.update { $0.appearance.theme = theme }
                }
            }
        }
        menu.addSubmenu(tr("dock.menu.addWidget", "Add Widget"), symbol: "plus.rectangle.on.rectangle") { submenu in
            for category in WidgetCategory.allCases {
                let kinds = WidgetKind.addable.filter { $0.category == category }
                guard !kinds.isEmpty else { continue }
                submenu.addSubmenu(category.displayName, symbol: category.symbol) { group in
                    for kind in kinds {
                        let item = group.add(kind.displayName, symbol: kind.symbol) { [weak self] in self?.addWidget(kind) }
                        item.toolTip = kind.summary
                    }
                }
            }
            if !current.collections.isEmpty { submenu.addSeparator() }
            for collection in current.collections {
                submenu.add(collection.name, symbol: collection.symbol) { [weak self] in self?.addWidget(.quickLaunch, collection: collection.id) }
            }
        }
        menu.add(tr("dock.menu.addApplication", "Add Application…"), symbol: "plus.app") { [weak self] in self?.chooseApplicationToPin() }
        menu.addSeparator()
        menu.add(tr("dock.menu.magnification", "Magnification"), state: current.appearance.magnificationEnabled ? .on : .off) { [weak self] in
            self?.settings.update { $0.appearance.magnificationEnabled.toggle() }
        }
        menu.add(tr("dock.menu.autoHide", "Automatically Hide"), state: current.behavior.autoHide ? .on : .off) { [weak self] in
            self?.settings.update { $0.behavior.autoHide.toggle() }
            self?.windowController.applyAutoHideSetting()
        }
        menu.addSeparator()
        menu.add(tr("dock.menu.missionControl", "AI Mission Control"), symbol: "sparkles.rectangle.stack") { [weak self] in self?.openMissionControl() }
        menu.add(tr("dock.menu.settings", "Dock Settings…"), symbol: "gearshape") { [weak self] in self?.openSettings() }
    }

    func switchWorkspace(to id: UUID) {
        settings.update { $0.activeWorkspaceID = id }
        model.rebuild()
    }

    func addWidget(_ kind: WidgetKind, collection: UUID? = nil) {
        settings.update { settings in
            settings.updateActiveWorkspace { $0.widgets.append(WidgetPlacement(kind: kind, collectionID: collection)) }
        }
        model.rebuild()
    }

    func chooseApplicationToPin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application, .folder]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = tr("dock.addApp.prompt", "Add to Dock")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let items: [PinnedItem] = panel.urls.map { url in
            url.pathExtension == "app" ? .application(bundleIdentifier: Bundle(url: url)?.bundleIdentifier, url: url) : .folder(url)
        }
        pin(items, at: nil)
    }

    private func explainAccessibility() {
        let alert = NSAlert()
        alert.messageText = tr("permissions.accessibility.title", "Show window titles in the Dock menu")
        alert.informativeText = tr("permissions.accessibility.body", "PulseDock needs Accessibility access to list, restore and raise the windows of other apps. Without it, PulseDock still opens and switches apps. You can turn it off at any time in System Settings › Privacy & Security › Accessibility.")
        alert.addButton(withTitle: tr("permissions.accessibility.continue", "Continue"))
        alert.addButton(withTitle: tr("common.notNow", "Not Now"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            WindowInventory.requestAccessibilityAccess()
        }
    }

    private func confirmEmptyTrash() {
        let alert = NSAlert()
        alert.messageText = tr("dock.emptyTrash.title", "Empty the Trash?")
        alert.informativeText = tr("dock.emptyTrash.body", "Items in the Trash will be deleted immediately. Finder performs the deletion; macOS may ask whether PulseDock can control Finder.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("dock.emptyTrash.confirm", "Empty Trash"))
        alert.addButton(withTitle: tr("common.cancel", "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppleScriptRunner.run("tell application id \"com.apple.finder\" to empty trash") { error in
            if let error { PulseLog.dock.error("Empty Trash failed: \(error, privacy: .public)") }
        }
    }
}

extension ThemeID {
    var displayName: String {
        switch self {
        case .nativeGlass: tr("theme.nativeGlass", "Native Glass")
        case .midnight: tr("theme.midnight", "Midnight")
        case .aurora: tr("theme.aurora", "Aurora")
        }
    }
}
