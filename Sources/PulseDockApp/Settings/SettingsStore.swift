import AgentBridge
import Diagnostics
import DockCore
import Foundation
import Observation
import Persistence

/// Owns `AppSettings`: loads them from SQLite at launch and saves changes (debounced).
@Observable
final class SettingsStore {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            for observer in observers { observer(oldValue, settings) }
            scheduleSave()
            if settings.sanitizerOptions != oldValue.sanitizerOptions { writeHelperConfig() }
            if settings.general.language != oldValue.general.language { applyLanguagePreference() }
        }
    }

    @ObservationIgnored private let persistence: PersistenceController?
    @ObservationIgnored private var observers: [(AppSettings, AppSettings) -> Void] = []

    /// Registers a callback for every change (old value, new value). Used by non-SwiftUI
    /// components such as the dock window and the agent services.
    func observe(_ observer: @escaping (AppSettings, AppSettings) -> Void) {
        observers.append(observer)
    }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    static let key = "app.settings.v1"

    init(persistence: PersistenceController?) {
        self.persistence = persistence
        if let stored = persistence?.loadSetting(AppSettings.self, key: SettingsStore.key) {
            settings = stored
        } else {
            settings = AppSettings()
        }
        for index in settings.workspaces.indices where settings.workspaces[index].preset == nil {
            settings.workspaces[index].preset = WorkspacePreset.infer(name: settings.workspaces[index].name, symbol: settings.workspaces[index].symbol)
        }
        if settings.workspaces.isEmpty {
            settings.workspaces = WorkspaceDefaults.make()
            settings.activeWorkspaceID = settings.workspaces.first?.id
            saveNow()
        }
        writeHelperConfig()
    }

    var activeWorkspace: Workspace {
        settings.activeWorkspace ?? WorkspaceDefaults.make()[0]
    }

    func update(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
    }

    func saveNow() {
        saveTask?.cancel()
        persistence?.saveSetting(settings, key: SettingsStore.key)
    }

    func flush() {
        saveNow()
        persistence?.flush()
    }

    /// Settings › Advanced › Reset: back to defaults (workspaces rebuilt from the macOS Dock).
    func resetToDefaults() {
        var fresh = AppSettings()
        fresh.workspaces = WorkspaceDefaults.make()
        fresh.activeWorkspaceID = fresh.workspaces.first?.id
        fresh.hasCompletedOnboarding = settings.hasCompletedOnboarding
        fresh.systemDockRestorePoint = settings.systemDockRestorePoint
        settings = fresh
        saveNow()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// The hook helper reads its privacy options from this file before sanitizing.
    private func writeHelperConfig() {
        do {
            try BridgePaths.ensurePrivateDirectory(BridgePaths.supportDirectory)
            try settings.sanitizerOptions.save()
        } catch {
            PulseLog.app.error("Could not write helper config: \(String(describing: error), privacy: .public)")
        }
    }

    /// Language changes apply at the next launch (standard macOS behaviour).
    private func applyLanguagePreference() {
        switch settings.general.language {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .portuguese: UserDefaults.standard.set([settings.general.language.rawValue], forKey: "AppleLanguages")
        }
    }
}

/// First-run workspaces. Development is a focused coding set (apps launcher, terminal, editor,
/// Claude, resource usage and music); Personal starts from the user's macOS Dock; the others
/// only contain apps that are actually installed.
enum WorkspaceDefaults {
    static let creativeBundleIDs = [
        "com.figma.Desktop", "com.bohemiancoding.sketch3", "com.pixelmatorteam.pixelmator.x", "com.seriflabs.affinitydesigner2",
        "com.seriflabs.affinityphoto2", "com.adobe.Photoshop", "com.adobe.illustrator", "com.apple.FinalCut", "com.apple.logic10",
        "org.blenderfoundation.blender", "com.apple.garageband10", "com.apple.iMovieApp", "com.apple.Photos",
    ]
    static let personalBundleIDs = [
        "com.apple.Music", "com.spotify.client", "com.apple.Photos", "com.apple.MobileSMS", "com.apple.mail", "com.apple.iCal",
        "com.apple.Notes", "com.apple.Safari", "com.apple.TV", "com.apple.podcasts",
    ]
    /// The apps launcher: Apps on macOS 26 and later, Launchpad before.
    static let launcherBundleIDs = ["com.apple.apps.launcher", "com.apple.launchpad.launcher"]
    /// Terminal is always installed; the others are only used when Terminal is missing.
    static let terminalBundleIDs = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]
    /// VS Code first, then other editors.
    static let editorBundleIDs = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode", "com.jetbrains.intellij"]
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    static var finder: PinnedItem {
        PinnedItem.application(bundleIdentifier: "com.apple.finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
    }

    static func make() -> [Workspace] {
        WorkspacePreset.allCases.map(workspace)
    }

    /// A fresh workspace for the preset (also used by "Restore Defaults").
    static func workspace(_ preset: WorkspacePreset) -> Workspace {
        switch preset {
        case .development:
            let pinned = firstInstalled(launcherBundleIDs) + firstInstalled(terminalBundleIDs) + firstInstalled(editorBundleIDs) + installed([claudeBundleID])
            return Workspace(name: preset.localizedName, symbol: "chevron.left.forwardslash.chevron.right",
                             pinned: pinned, theme: nil,
                             widgets: [WidgetPlacement(kind: .systemHealth), WidgetPlacement(kind: .nowPlaying)],
                             showRunningApps: true, agentFilter: .all, preset: preset)
        case .creative:
            return Workspace(name: preset.localizedName, symbol: "paintpalette",
                             pinned: [finder] + installed(creativeBundleIDs), theme: .aurora,
                             widgets: [WidgetPlacement(kind: .nowPlaying), WidgetPlacement(kind: .clock)],
                             showRunningApps: true, agentFilter: .all, preset: preset)
        case .personal:
            var pinned = SystemDockImporter.persistentApps().map { PinnedItem.application(bundleIdentifier: $0.bundleIdentifier, url: $0.url) }
            if !pinned.contains(where: { $0.bundleIdentifier == "com.apple.finder" }) { pinned.insert(finder, at: 0) }
            if pinned.count <= 1 { pinned += installed(personalBundleIDs) }
            return Workspace(name: preset.localizedName, symbol: "house",
                             pinned: pinned, theme: nil,
                             widgets: [WidgetPlacement(kind: .nowPlaying), WidgetPlacement(kind: .clock)],
                             showRunningApps: true, agentFilter: .all, preset: preset)
        case .focus:
            return Workspace(name: preset.localizedName, symbol: "scope",
                             pinned: [finder] + firstInstalled(terminalBundleIDs) + firstInstalled(editorBundleIDs), theme: .midnight,
                             widgets: [WidgetPlacement(kind: .clock)],
                             showRunningApps: false, agentFilter: .attentionOnly, preset: preset)
        }
    }

    /// Puts the preset's apps, widgets and display options back, keeping the workspace's
    /// identity and the name the user gave it.
    static func restore(_ workspace: inout Workspace) {
        guard let preset = workspace.preset else { return }
        let fresh = Self.workspace(preset)
        workspace.pinned = fresh.pinned
        workspace.widgets = fresh.widgets
        workspace.theme = fresh.theme
        workspace.showRunningApps = fresh.showRunningApps
        workspace.agentFilter = fresh.agentFilter
        workspace.symbol = fresh.symbol
    }

    static func firstInstalled(_ bundleIDs: [String]) -> [PinnedItem] {
        Array(installed(bundleIDs).prefix(1))
    }

    static func installed(_ bundleIDs: [String]) -> [PinnedItem] {
        bundleIDs.compactMap { id in
            NSWorkspaceLookup.url(forBundleIdentifier: id).map { PinnedItem.application(bundleIdentifier: id, url: $0) }
        }
    }
}
