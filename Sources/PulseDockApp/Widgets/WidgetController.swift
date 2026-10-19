import AppKit
import DockCore
import DockRendering
import SwiftUI
import WidgetCore

/// Owns the widget data providers (one instance each, shared by every placement) and
/// presents their expanded panels.
final class WidgetController {
    let clock = ClockProvider()
    let health = SystemHealthProvider()
    let nowPlaying = NowPlayingProvider()
    private let settings: SettingsStore
    private let accessibility: AccessibilityOptions
    private weak var dockWindow: DockWindowController?
    private var panel: AnchoredPanel?
    var openSettings: () -> Void = {}

    init(settings: SettingsStore, accessibility: AccessibilityOptions, dockWindow: DockWindowController) {
        self.settings = settings
        self.accessibility = accessibility
        self.dockWindow = dockWindow
        updateVisibility()
    }

    private var theme: Theme { Theme.theme(for: settings.settings.effectiveTheme) }

    /// Providers only sample while a placement is visible and the dock is shown.
    func updateVisibility(dockVisible: Bool = true) {
        let kinds = Set(settings.activeWorkspace.widgets.map(\.kind))
        clock.isVisible = dockVisible && kinds.contains(.clock)
        health.isVisible = dockVisible && kinds.contains(.systemHealth)
    }

    func tile(for placement: WidgetPlacement, size: CGSize) -> AnyView {
        let theme = theme
        switch placement.kind {
        case .clock: return AnyView(ClockTile(clock: clock, theme: theme))
        case .systemHealth: return AnyView(SystemHealthTile(health: health, theme: theme))
        case .nowPlaying: return AnyView(NowPlayingTile(player: nowPlaying, theme: theme))
        case .quickLaunch: return AnyView(EmptyView())
        }
    }

    func showPanel(for placement: WidgetPlacement, anchor: CGRect) {
        if panel?.isVisible == true {
            panel?.dismiss()
            return
        }
        let theme = theme
        let content: AnyView
        let size: CGSize
        switch placement.kind {
        case .clock:
            content = AnyView(ClockPanel(clock: clock, theme: theme, accessibility: accessibility))
            size = CGSize(width: 260, height: 300)
        case .systemHealth:
            content = AnyView(SystemHealthPanel(health: health, theme: theme, accessibility: accessibility))
            size = CGSize(width: 300, height: 300)
        case .nowPlaying:
            content = AnyView(NowPlayingPanel(player: nowPlaying, theme: theme, accessibility: accessibility))
            size = CGSize(width: 300, height: 230)
        case .quickLaunch:
            let collection = settings.settings.collections.first { $0.id == placement.collectionID }
            let rows = max(1, ((collection?.items.count ?? 0) + 3) / 4)
            content = AnyView(QuickLaunchPanel(collection: collection, theme: theme, accessibility: accessibility,
                                               open: { [weak self] item in self?.open(item) },
                                               edit: { [weak self] in
                                                   self?.panel?.dismiss()
                                                   self?.openSettings()
                                               }))
            size = CGSize(width: 352, height: Double(rows) * 78 + 90)
        }
        let panel = self.panel ?? AnchoredPanel(allowsKey: true)
        panel.onClose = { [weak self] in self?.dockWindow?.isPresentingAuxiliaryUI = false }
        self.panel = panel
        dockWindow?.isPresentingAuxiliaryUI = true
        panel.present(content, size: size, above: anchor, gap: 12)
    }

    private func open(_ item: PinnedItem) {
        panel?.dismiss()
        guard let url = NSWorkspaceLookup.resolve(item) else { return }
        if url.pathExtension == "app" {
            AppLauncher.openOrActivate(applicationAt: url)
        } else {
            AppLauncher.open(url)
        }
    }
}
