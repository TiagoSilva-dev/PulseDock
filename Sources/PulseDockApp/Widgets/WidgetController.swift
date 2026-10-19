import AgentCore
import AppKit
import Diagnostics
import DockCore
import DockRendering
import Persistence
import SwiftUI
import UserNotifications
import WidgetCore

/// Owns the widget data providers (one instance per kind, shared by every placement, except
/// where a placement has its own source such as a folder or a city) and presents their
/// expanded panels. Providers only do work while a placement is in the dock and the dock is
/// visible.
final class WidgetController {
    let clock = ClockProvider()
    let health = SystemHealthProvider()
    let nowPlaying = NowPlayingProvider()
    let timers = FocusTimersProvider()
    let network = NetworkRateProvider()
    let clipboard = ClipboardHistory()
    let shortcuts = ShortcutsRunner()
    let recorder = AgentActivityRecorder()
    let data: WidgetDataStore
    let cinema: CinemaController
    let claudeUsage: ClaudeUsageService
    private(set) lazy var events = EventKitProvider()
    private var weather: [UUID: WeatherProvider] = [:]
    private var folders: [UUID: FolderWatcher] = [:]
    private lazy var screenshots = FolderWatcher(folder: FolderWatcher.screenshotsFolder(), limit: 15, filter: { FolderWatcher.isScreenCapture($0) })

    private let settings: SettingsStore
    private let agents: AgentStore
    private let accessibility: AccessibilityOptions
    private weak var dockWindow: DockWindowController?
    private var panel: AnchoredPanel?
    private var presentedPlacement: UUID?
    var openSettings: () -> Void = {}
    var openSession: (SessionKey) -> Void = { _ in }
    var connectClaudeUsage: () -> Void = {}

    init(settings: SettingsStore, agents: AgentStore, persistence: PersistenceController?, accessibility: AccessibilityOptions, dockWindow: DockWindowController) {
        self.settings = settings
        self.agents = agents
        self.accessibility = accessibility
        self.dockWindow = dockWindow
        data = WidgetDataStore(persistence: persistence)
        cinema = CinemaController(data: data, accessibility: accessibility)
        claudeUsage = ClaudeUsageService(data: data)
        timers.completedFocusByDay = data.data.pomodoroFocusByDay
        timers.timer.reset(duration: data.data.timerMinutes * 60)
        timers.onFinished = { [weak self] kind, wasFocus in self?.timerFinished(kind: kind, wasFocus: wasFocus) }
        clipboard.restorePinned(data.data.pinnedClipboard)
        clipboard.onPinnedChange = { [weak self] pinned in self?.data.update { $0.pinnedClipboard = pinned } }
        cinema.dockFrame = { [weak dockWindow] in dockWindow?.panel.frame }
        cinema.themeProvider = { [weak self] in self?.theme ?? .nativeGlass }
        updateVisibility()
    }

    private var theme: Theme { Theme.theme(for: settings.settings.effectiveTheme) }

    private var placements: [WidgetPlacement] { settings.activeWorkspace.widgets }

    /// Providers only sample while a placement is visible and the dock is shown.
    func updateVisibility(dockVisible: Bool = true) {
        let current = placements
        let kinds = Set(current.map(\.kind))
        clock.isVisible = dockVisible && !kinds.isDisjoint(with: [.clock, .calendar, .countdown, .timeProgress, .water])
        health.isVisible = dockVisible && !kinds.isDisjoint(with: [.systemHealth, .battery])
        network.isVisible = dockVisible && kinds.contains(.network)
        // The clipboard history must keep listening while the dock is hidden (copies still happen).
        clipboard.isEnabled = kinds.contains(.clipboard)
        if kinds.contains(.calendar) || kinds.contains(.reminders) {
            events.wantsCalendar = kinds.contains(.calendar)
            events.wantsReminders = kinds.contains(.reminders)
        }
        screenshotsActive(dockVisible && kinds.contains(.screenshots))

        // Per-placement sources: weather by city, folders by path.
        let weatherIDs = Set(current.filter { $0.kind == .weather }.map(\.id))
        for (id, provider) in weather where !weatherIDs.contains(id) {
            provider.isVisible = false
            weather[id] = nil
        }
        for placement in current where placement.kind == .weather {
            let provider = weatherProvider(for: placement)
            provider.isVisible = dockVisible
        }
        let folderIDs = Set(current.filter { $0.kind == .files }.map(\.id))
        for (id, watcher) in folders where !folderIDs.contains(id) {
            watcher.isActive = false
            folders[id] = nil
        }
        for placement in current where placement.kind == .files {
            folderWatcher(for: placement).isActive = dockVisible
        }
    }

    private func screenshotsActive(_ active: Bool) {
        if active || screenshotsLoaded { screenshots.isActive = active }
        if active { screenshotsLoaded = true }
    }
    private var screenshotsLoaded = false

    private func weatherProvider(for placement: WidgetPlacement) -> WeatherProvider {
        let provider = weather[placement.id] ?? WeatherProvider()
        let options = placement.settings
        if provider.fahrenheit != (options.fahrenheit == true) { provider.fahrenheit = options.fahrenheit == true }
        if provider.place != options.weatherPlace { provider.place = options.weatherPlace }
        weather[placement.id] = provider
        return provider
    }

    private func folderWatcher(for placement: WidgetPlacement) -> FolderWatcher {
        let folder = placement.settings.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        if let existing = folders[placement.id], existing.folder == folder { return existing }
        folders[placement.id]?.isActive = false
        let watcher = FolderWatcher(folder: folder, limit: 14)
        folders[placement.id] = watcher
        return watcher
    }

    /// Writes new options for one placement (the dock and any open panel update live).
    func updateOptions(_ id: UUID, _ options: WidgetOptions) {
        settings.update { settings in
            settings.updateActiveWorkspace { workspace in
                guard let index = workspace.widgets.firstIndex(where: { $0.id == id }) else { return }
                workspace.widgets[index].options = options
            }
        }
        if let placement = placements.first(where: { $0.id == id }) {
            if placement.kind == .weather { _ = weatherProvider(for: placement) }
            if placement.kind == .files { folderWatcher(for: placement).isActive = true }
        }
    }

    /// Records agent events (Agent Heartbeat, Pulse Buddy).
    func agentEvents(_ events: [AgentEvent]) {
        recorder.record(events)
    }

    func agentSummaryChanged(_ summary: AggregateSummary) {
        // "Codex · Approval needed" — which agent, and a DEMO label for simulated sessions.
        let headline = summary.sessions.first { $0.category == .attention }.map { presentation in
            let base = "\(presentation.session.key.provider.shortName) · \(agents.text.headline(for: presentation))"
            return presentation.session.isDemo ? "\(base) · \(tr("demo.badge", "DEMO"))" : base
        }
        cinema.agentAttentionChanged(count: summary.attentionCount, headline: headline)
    }

    // MARK: Tiles

    func tile(for placement: WidgetPlacement, size: CGSize) -> AnyView {
        let theme = theme
        let options = placement.settings
        switch placement.kind {
        case .clock: return AnyView(ClockTile(clock: clock, options: options, theme: theme))
        case .systemHealth: return AnyView(SystemHealthTile(health: health, theme: theme))
        case .nowPlaying: return AnyView(NowPlayingTile(player: nowPlaying, theme: theme))
        case .quickLaunch: return AnyView(EmptyView())
        case .calendar: return AnyView(CalendarTile(events: events, clock: clock, theme: theme))
        case .timer: return AnyView(TimerTile(timers: timers, theme: theme))
        case .stopwatch: return AnyView(StopwatchTile(timers: timers, theme: theme))
        case .pomodoro: return AnyView(PomodoroTile(timers: timers, theme: theme))
        case .countdown: return AnyView(CountdownTile(options: options, clock: clock, theme: theme))
        case .timeProgress: return AnyView(TimeProgressTile(options: options, clock: clock, theme: theme))
        case .reminders: return AnyView(RemindersTile(events: events, theme: theme))
        case .note: return AnyView(NoteTile(text: data.data.notes[placement.id.uuidString] ?? "", theme: theme))
        case .shortcuts: return AnyView(ShortcutsTile(runner: shortcuts, theme: theme))
        case .water: return AnyView(WaterTile(data: data, options: options, clock: clock, theme: theme))
        case .files: return AnyView(FilesTile(watcher: folderWatcher(for: placement), lastSeen: data.data.filesLastSeen[placement.id.uuidString], theme: theme))
        case .shelf: return AnyView(ShelfTile(count: data.data.shelf.count, theme: theme))
        case .airDrop: return AnyView(AirDropTile(isTargeted: false, theme: theme))
        case .screenshots: return AnyView(ScreenshotsTile(watcher: screenshots, theme: theme))
        case .clipboard: return AnyView(ClipboardTile(history: clipboard, theme: theme))
        case .colorPicker: return AnyView(ColorPickerTile(recent: data.data.recentColors, theme: theme))
        case .emoji:
            let ranked = EmojiCatalog.ranked(data.data.emojiUsage, limit: 1)
            return AnyView(EmojiTile(favorites: ranked.isEmpty ? EmojiCatalog.defaultFavorites : ranked))
        case .converter: return AnyView(SymbolTile(symbol: "arrow.left.arrow.right.circle", theme: theme))
        case .network: return AnyView(NetworkTile(network: network, theme: theme))
        case .battery: return AnyView(BatteryTile(health: health, theme: theme))
        case .weather: return AnyView(WeatherTile(weather: weatherProvider(for: placement), theme: theme))
        case .cinema: return AnyView(CinemaTile(cinema: cinema, theme: theme))
        case .claudeUsage: return AnyView(ClaudeUsageTile(usage: claudeUsage, theme: theme))
        case .agentHeartbeat: return AnyView(HeartbeatTile(recorder: recorder, store: agents, theme: theme, accessibility: accessibility))
        case .pulseBuddy: return AnyView(PulseBuddyTile(store: agents, theme: theme, accessibility: accessibility))
        }
    }

    // MARK: Panels

    func showPanel(for placement: WidgetPlacement, anchor: CGRect) {
        if panel?.isVisible == true {
            let wasSame = presentedPlacement == placement.id
            panel?.dismiss()
            if wasSame { return }
        }
        if placement.kind == .colorPicker, NSEvent.modifierFlags.contains(.option) {
            pickColor()
            return
        }
        let (content, maxSize) = panelContent(for: placement)
        // The clock keeps its size: its time zone list needs the room while choosing.
        let size = placement.kind == .clock ? maxSize : fittedSize(content, maxSize: maxSize)
        let panel = self.panel ?? AnchoredPanel(allowsKey: true)
        panel.onClose = { [weak self] in
            self?.dockWindow?.isPresentingAuxiliaryUI = false
            self?.presentedPlacement = nil
        }
        self.panel = panel
        presentedPlacement = placement.id
        dockWindow?.isPresentingAuxiliaryUI = true
        panel.present(content, size: size, above: anchor, gap: 12)
        if placement.kind == .files {
            data.update { $0.filesLastSeen[placement.id.uuidString] = Date() }
        }
    }

    /// Panels take the height their content needs, up to the size given per widget (long
    /// lists scroll inside that ceiling).
    private func fittedSize(_ content: AnyView, maxSize: CGSize) -> CGSize {
        // `fittingSize` asks for the ideal size (no height proposed), so flexible frames take
        // their content's height instead of all the space offered.
        let ideal = NSHostingView(rootView: content.frame(width: maxSize.width)).fittingSize
        guard ideal.height.isFinite, ideal.height > 0 else { return maxSize }
        return CGSize(width: maxSize.width, height: min(maxSize.height, max(140, ideal.height.rounded(.up))))
    }

    private func panelContent(for placement: WidgetPlacement) -> (AnyView, CGSize) {
        let theme = theme
        let id = placement.id
        let live = LiveOptions(settings: settings, id: id)
        let update: (WidgetOptions) -> Void = { [weak self] in self?.updateOptions(id, $0) }
        switch placement.kind {
        case .clock:
            return (AnyView(live { [clock, accessibility] options in ClockPanel(clock: clock, options: options, theme: theme, accessibility: accessibility, update: update) }),
                    CGSize(width: 300, height: placement.settings.isOtherTimeZone ? 360 : 470))
        case .systemHealth:
            return (AnyView(SystemHealthPanel(health: health, theme: theme, accessibility: accessibility)), CGSize(width: 300, height: 300))
        case .nowPlaying:
            return (AnyView(NowPlayingPanel(player: nowPlaying, theme: theme, accessibility: accessibility)), CGSize(width: 300, height: 230))
        case .quickLaunch:
            let collection = settings.settings.collections.first { $0.id == placement.collectionID }
            let rows = max(1, ((collection?.items.count ?? 0) + 3) / 4)
            return (AnyView(QuickLaunchPanel(collection: collection, theme: theme, accessibility: accessibility,
                                             open: { [weak self] item in self?.open(item) },
                                             edit: { [weak self] in
                                                 self?.panel?.dismiss()
                                                 self?.openSettings()
                                             })),
                    CGSize(width: 352, height: Double(rows) * 78 + 90))
        case .calendar:
            events.wantsCalendar = true
            events.refresh()
            return (AnyView(CalendarPanel(events: events, theme: theme, accessibility: accessibility)), CGSize(width: 330, height: 420))
        case .timer:
            return (AnyView(TimerPanel(timers: timers, data: data, theme: theme, accessibility: accessibility)), CGSize(width: 320, height: 300))
        case .stopwatch:
            return (AnyView(StopwatchPanel(timers: timers, theme: theme, accessibility: accessibility)), CGSize(width: 300, height: 290))
        case .pomodoro:
            return (AnyView(PomodoroPanel(timers: timers, theme: theme, accessibility: accessibility)), CGSize(width: 320, height: 330))
        case .countdown:
            return (AnyView(live { [clock, accessibility] options in CountdownPanel(options: options, clock: clock, theme: theme, accessibility: accessibility, update: update) }),
                    CGSize(width: 300, height: 450))
        case .timeProgress:
            return (AnyView(live { [clock, accessibility] options in TimeProgressPanel(options: options, clock: clock, theme: theme, accessibility: accessibility, update: update) }),
                    CGSize(width: 290, height: 300))
        case .reminders:
            events.wantsReminders = true
            events.refresh()
            return (AnyView(RemindersPanel(events: events, theme: theme, accessibility: accessibility)), CGSize(width: 320, height: 400))
        case .note:
            return (AnyView(NotePanel(placementID: id, data: data, theme: theme, accessibility: accessibility)), CGSize(width: 340, height: 320))
        case .shortcuts:
            return (AnyView(ShortcutsPanel(runner: shortcuts, theme: theme, accessibility: accessibility)), CGSize(width: 300, height: 380))
        case .water:
            return (AnyView(live { [data, clock, accessibility] options in WaterPanel(data: data, options: options, clock: clock, theme: theme, accessibility: accessibility, update: update) }),
                    CGSize(width: 320, height: 300))
        case .files:
            let watcher = folderWatcher(for: placement)
            watcher.reload()
            return (AnyView(FilesPanel(watcher: watcher, theme: theme, accessibility: accessibility) { [weak self] in self?.chooseFolder(for: id) }),
                    CGSize(width: 330, height: 420))
        case .shelf:
            return (AnyView(ShelfPanel(data: data, theme: theme, accessibility: accessibility) { [weak self] urls in self?.airDrop(urls) }),
                    CGSize(width: 320, height: 340))
        case .airDrop:
            return (AnyView(AirDropPanel(theme: theme, accessibility: accessibility) { [weak self] urls in self?.airDrop(urls) }), CGSize(width: 290, height: 170))
        case .screenshots:
            screenshotsActive(true)
            screenshots.reload()
            return (AnyView(ScreenshotsPanel(watcher: screenshots, theme: theme, accessibility: accessibility)), CGSize(width: 372, height: 380))
        case .clipboard:
            return (AnyView(ClipboardPanel(history: clipboard, theme: theme, accessibility: accessibility) { [weak self] in self?.panel?.dismiss() }),
                    CGSize(width: 340, height: 440))
        case .colorPicker:
            return (AnyView(ColorPickerPanel(data: data, theme: theme, accessibility: accessibility) { [weak self] in self?.pickColor() }),
                    CGSize(width: 330, height: 300))
        case .emoji:
            return (AnyView(EmojiPanel(data: data, theme: theme, accessibility: accessibility)), CGSize(width: 330, height: 360))
        case .converter:
            return (AnyView(ConverterPanel(theme: theme, accessibility: accessibility)), CGSize(width: 320, height: 250))
        case .network:
            return (AnyView(NetworkPanel(network: network, theme: theme, accessibility: accessibility)), CGSize(width: 300, height: 250))
        case .battery:
            return (AnyView(BatteryPanel(health: health, theme: theme, accessibility: accessibility)), CGSize(width: 280, height: 200))
        case .weather:
            let provider = weatherProvider(for: placement)
            provider.refresh(force: false)
            return (AnyView(live { [accessibility] options in WeatherPanel(weather: provider, options: options, theme: theme, accessibility: accessibility, update: update) }),
                    CGSize(width: 340, height: placement.settings.weatherPlace == nil ? 280 : 470))
        case .cinema:
            return (AnyView(CinemaPanel(cinema: cinema, theme: theme, accessibility: accessibility)), CGSize(width: 360, height: cinema.queue.isEmpty ? 500 : 620))
        case .agentHeartbeat:
            return (AnyView(HeartbeatPanel(recorder: recorder, store: agents, theme: theme, accessibility: accessibility) { [weak self] key in
                self?.panel?.dismiss()
                self?.openSession(key)
            }), CGSize(width: 360, height: 440))
        case .claudeUsage:
            return (AnyView(ClaudeUsagePanel(usage: claudeUsage, settings: settings, theme: theme, accessibility: accessibility) { [weak self] in
                self?.panel?.dismiss()
                self?.connectClaudeUsage()
            }), CGSize(width: 360, height: 540))
        case .pulseBuddy:
            return (AnyView(PulseBuddyPanel(store: agents, recorder: recorder, theme: theme, accessibility: accessibility)), CGSize(width: 320, height: 250))
        }
    }

    // MARK: Drops

    func acceptsDrop(_ placement: WidgetPlacement, pasteboard: NSPasteboard) -> Bool {
        switch placement.kind {
        case .airDrop, .shelf: !fileURLs(pasteboard).isEmpty
        case .cinema: !cinema.links(from: pasteboard).isEmpty
        case .note: pasteboard.string(forType: .string)?.isEmpty == false
        default: false
        }
    }

    func performDrop(_ placement: WidgetPlacement, pasteboard: NSPasteboard) -> Bool {
        switch placement.kind {
        case .airDrop:
            airDrop(fileURLs(pasteboard))
            return true
        case .shelf:
            let paths = fileURLs(pasteboard).map(\.path)
            data.update { store in
                for path in paths where !store.shelf.contains(path) { store.shelf.append(path) }
            }
            dockWindow?.model.rebuild()
            return true
        case .cinema:
            let links = cinema.links(from: pasteboard)
            for (index, link) in links.enumerated() { cinema.add(link: link, playNow: index == 0 && !cinema.isPlaying) }
            return !links.isEmpty
        case .note:
            guard let text = pasteboard.string(forType: .string) else { return false }
            let key = placement.id.uuidString
            data.update { store in
                let existing = store.notes[key] ?? ""
                store.notes[key] = String((existing.isEmpty ? text : existing + "\n" + text).prefix(20_000))
            }
            return true
        default:
            return false
        }
    }

    private func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: Actions

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        panel?.dismiss()
        if service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        } else {
            PulseLog.widgets.error("AirDrop is not available for these items")
        }
    }

    /// The system color sampler (loupe). The HEX code is copied and kept in the recent list.
    func pickColor() {
        panel?.dismiss()
        NSColorSampler().show { [weak self] color in
            guard let color else { return }
            MainActor.assumeIsolated {
                let hex = ColorFormat.hex(color)
                Pasteboard.copy(hex)
                self?.data.update { store in
                    store.recentColors.removeAll { $0 == hex }
                    store.recentColors.insert(hex, at: 0)
                    store.recentColors = Array(store.recentColors.prefix(27))
                }
                self?.dockWindow?.model.rebuild()
            }
        }
    }

    private func chooseFolder(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = tr("files.choose", "Choose")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard var options = placements.first(where: { $0.id == id })?.settings else { return }
        options.folderPath = url.path
        updateOptions(id, options)
        self.panel?.dismiss()
    }

    private func timerFinished(kind: String, wasFocus: Bool) {
        data.update { $0.pomodoroFocusByDay = timers.completedFocusByDay }
        NSSound(named: "Glass")?.play()
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        if kind == "pomodoro" {
            content.title = wasFocus ? tr("pomodoro.focusDone", "Focus session done") : tr("pomodoro.breakDone", "Break is over")
            content.body = wasFocus ? tr("pomodoro.focusDoneBody", "Time for a break.") : tr("pomodoro.breakDoneBody", "Back to focus.")
        } else {
            content.title = tr("timer.done", "Timer finished")
        }
        content.sound = nil
        content.threadIdentifier = "pulsedock.widgets"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pulsedock.timer.\(kind)", content: content, trigger: nil))
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

/// Re-reads a placement's options from the settings store, so an open panel reflects every
/// change it makes (for example a new time zone) without being rebuilt.
struct LiveOptions {
    let settings: SettingsStore
    let id: UUID

    func callAsFunction<Content: View>(@ViewBuilder _ content: @escaping (WidgetOptions) -> Content) -> some View {
        LiveOptionsView(settings: settings, id: id, content: content)
    }
}

private struct LiveOptionsView<Content: View>: View {
    let settings: SettingsStore
    let id: UUID
    let content: (WidgetOptions) -> Content

    var body: some View {
        let placement = settings.settings.workspaces.lazy.flatMap(\.widgets).first { $0.id == id }
        content(placement?.settings ?? WidgetOptions())
    }
}
