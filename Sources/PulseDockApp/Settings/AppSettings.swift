import AgentBridge
import DockCore
import DockRendering
import Foundation
import WidgetCore

nonisolated enum OperatingMode: String, Codable, CaseIterable, Sendable {
    /// PulseDock complements the macOS Dock, which stays untouched (default).
    case companion
    /// PulseDock is the main dock; the macOS Dock is set to auto-hide with consent.
    case replacement
}

nonisolated enum LanguagePreference: String, Codable, CaseIterable, Sendable {
    case system
    case english = "en"
    case portuguese = "pt-BR"
}

nonisolated enum TransparencyLevel: String, Codable, CaseIterable, Sendable {
    case clear
    case standard
    case opaque
}

nonisolated enum BorderStyle: String, Codable, CaseIterable, Sendable {
    case none
    case subtle
    case defined
}

nonisolated enum SpacingStyle: String, Codable, CaseIterable, Sendable {
    case compact
    case standard
    case comfortable

    var multiplier: Double {
        switch self {
        case .compact: 0.7
        case .standard: 1
        case .comfortable: 1.3
        }
    }
}

nonisolated enum AgentFilter: String, Codable, CaseIterable, Sendable {
    /// Every live session.
    case all
    /// Only sessions that need the user (used by the Focus workspace).
    case attentionOnly
    /// Agent Pulse hidden in this workspace.
    case hidden
}

nonisolated enum WidgetKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case clock
    case systemHealth
    case nowPlaying
    case quickLaunch
    // Time
    case calendar, timer, stopwatch, pomodoro, countdown, timeProgress
    // Productivity
    case reminders, note, shortcuts, water
    // Files
    case files, shelf, airDrop, screenshots
    // Utilities
    case clipboard, colorPicker, emoji, converter
    // System and world
    case network, battery, weather
    // PulseDock originals
    case cinema, agentHeartbeat, pulseBuddy, claudeUsage

    var id: String { rawValue }
}

/// Per-placement options (each placement of the same widget can differ, for example two
/// clocks in different time zones). Every field is optional so older settings decode.
nonisolated struct WidgetOptions: Codable, Hashable, Sendable {
    var timeZoneID: String?
    var analogClock: Bool?
    var countdownTitle: String?
    var countdownDate: Date?
    var progressScope: TimeProgressScope?
    var weatherPlace: WeatherPlace?
    var fahrenheit: Bool?
    var waterGoal: Int?
    var folderPath: String?
}

nonisolated struct WidgetPlacement: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var kind: WidgetKind
    var collectionID: UUID?
    var options: WidgetOptions?

    var settings: WidgetOptions {
        get { options ?? WidgetOptions() }
        set { options = newValue }
    }
}

/// Decodes an array element by element, dropping elements that fail (for example a widget
/// added by a newer PulseDock), so one unknown entry never discards a whole workspace.
nonisolated struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(elements: [Element]) { self.elements = elements }

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        elements = result
    }
}

nonisolated struct QuickLaunchCollection: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var symbol: String
    var items: [PinnedItem]
}

/// A PulseDock environment: its own pinned apps, order, theme, widgets and agent filter.
/// Not related to macOS Spaces; switching never moves other apps' windows.
nonisolated struct Workspace: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var symbol: String
    var pinned: [PinnedItem]
    var theme: ThemeID?
    var widgets: [WidgetPlacement]
    var showRunningApps: Bool
    var agentFilter: AgentFilter
    /// The preset this workspace was created from. Until the user renames it, its name follows
    /// the interface language.
    var preset: WorkspacePreset?

    /// The name to show: the localized preset name while the stored name is still a default.
    var displayName: String {
        get {
            guard let preset, preset.defaultNames.contains(name) else { return name }
            return preset.localizedName
        }
        set { name = newValue }
    }
}

nonisolated enum WorkspacePreset: String, Codable, Hashable, Sendable, CaseIterable {
    case development, creative, personal, focus

    var localizedName: String {
        switch self {
        case .development: tr("workspace.development", "Development")
        case .creative: tr("workspace.creative", "Creative")
        case .personal: tr("workspace.personal", "Personal")
        case .focus: tr("workspace.focus", "Focus")
        }
    }

    /// Names this preset has had in any supported language (a stored name in this set was
    /// never typed by the user).
    var defaultNames: Set<String> {
        switch self {
        case .development: ["Development", "Desenvolvimento"]
        case .creative: ["Creative", "Criativo"]
        case .personal: ["Personal", "Pessoal"]
        case .focus: ["Focus", "Foco"]
        }
    }

    /// Recognises presets saved before `preset` existed, by their default name and symbol.
    static func infer(name: String, symbol: String) -> WorkspacePreset? {
        let symbols: [WorkspacePreset: String] = [
            .development: "chevron.left.forwardslash.chevron.right", .creative: "paintpalette", .personal: "house", .focus: "scope",
        ]
        return allCases.first { $0.defaultNames.contains(name) && symbols[$0] == symbol }
    }
}

nonisolated struct GeneralSettings: Codable, Hashable, Sendable {
    var operatingMode: OperatingMode = .companion
    var language: LanguagePreference = .system
    var showMenuBarItem = true
}

nonisolated struct AppearanceSettings: Codable, Hashable, Sendable {
    var theme: ThemeID = .nativeGlass
    var iconSize: Double = 54
    var magnificationEnabled = true
    var maxMagnification: Double = 1.45
    var transparency: TransparencyLevel = .standard
    var border: BorderStyle = .subtle
    var spacing: SpacingStyle = .standard
    var animationsEnabled = true
    var showHoverLabels = true
    var showRunningIndicators = true
}

nonisolated struct DockBehaviorSettings: Codable, Hashable, Sendable {
    var autoHide = false
    var revealDelay: Double = 0.12
    var hideDelay: Double = 0.6
    var display: DisplayPreference = .primary
    var bottomMargin: Double = 6
    /// Do not reveal over full-screen apps or borderless full-screen games.
    var avoidFullScreenApps = true
    var showTrash = true
}

nonisolated struct AgentSettings: Codable, Hashable, Sendable {
    var enabled = true
    var quickPeekDelay: Double = 0.7
    var workingQuietLimitMinutes: Double = 10
    var toolQuietLimitMinutes: Double = 45
    /// Discover Claude Code sessions from `~/.claude/sessions` (discovery and liveness only).
    var useSessionRegistry = true
    var showCompletionFlash = true
    var muted: [String] = []
    var pinned: [String] = []
}

nonisolated struct NotificationSettings: Codable, Hashable, Sendable {
    var enabled = true
    var attention = true
    var failures = true
    var completions = false
    /// Claude usage limits crossing 80% and 95% (from the status line).
    var usageLimits = true
    var playSound = true
    var quietHoursEnabled = false
    /// Minutes after midnight.
    var quietStart = 22 * 60
    var quietEnd = 7 * 60
}

nonisolated struct PrivacySettings: Codable, Hashable, Sendable {
    var privacyMode = false
    var storeHistory = true
    var storePaths = true
    var retentionDays = 14
    var commandDetail: SanitizerOptions.CommandDetail = .redacted
    var keepFilePaths = true
    var keepSearchQueries = true
}

nonisolated struct AdvancedSettings: Codable, Hashable, Sendable {
    var demoMode = false
    var forceLegacyMaterial = false
}

/// Remembers what Replacement Mode changed in the macOS Dock so it can be restored exactly.
nonisolated struct SystemDockRestorePoint: Codable, Hashable, Sendable {
    var autohide: Bool
    var autohideDelay: Double?
    var changedDelay: Bool
}

nonisolated struct AppSettings: Codable, Hashable, Sendable {
    var general = GeneralSettings()
    var appearance = AppearanceSettings()
    var behavior = DockBehaviorSettings()
    var agents = AgentSettings()
    var notifications = NotificationSettings()
    var privacy = PrivacySettings()
    var advanced = AdvancedSettings()
    var workspaces: [Workspace] = []
    var activeWorkspaceID: UUID?
    var collections: [QuickLaunchCollection] = []
    var hasCompletedOnboarding = false
    var systemDockRestorePoint: SystemDockRestorePoint?

    init() {}

    var activeWorkspace: Workspace? {
        workspaces.first { $0.id == activeWorkspaceID } ?? workspaces.first
    }

    var effectiveTheme: ThemeID {
        activeWorkspace?.theme ?? appearance.theme
    }

    mutating func updateActiveWorkspace(_ change: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == (activeWorkspaceID ?? workspaces.first?.id) }) else { return }
        change(&workspaces[index])
    }

    var sanitizerOptions: SanitizerOptions {
        SanitizerOptions(commandDetail: privacy.commandDetail, keepFilePaths: privacy.keepFilePaths, keepSearchQueries: privacy.keepSearchQueries)
    }
}

// MARK: - Tolerant decoding (unknown or missing keys fall back to defaults)

nonisolated extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

nonisolated extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case general, appearance, behavior, agents, notifications, privacy, advanced, workspaces, activeWorkspaceID,
             collections, hasCompletedOnboarding, systemDockRestorePoint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        general = c.value(.general, defaults.general)
        appearance = c.value(.appearance, defaults.appearance)
        behavior = c.value(.behavior, defaults.behavior)
        agents = c.value(.agents, defaults.agents)
        notifications = c.value(.notifications, defaults.notifications)
        privacy = c.value(.privacy, defaults.privacy)
        advanced = c.value(.advanced, defaults.advanced)
        workspaces = c.value(.workspaces, defaults.workspaces)
        activeWorkspaceID = c.value(.activeWorkspaceID, defaults.activeWorkspaceID)
        collections = c.value(.collections, defaults.collections)
        hasCompletedOnboarding = c.value(.hasCompletedOnboarding, false)
        systemDockRestorePoint = c.value(.systemDockRestorePoint, nil)
    }
}

nonisolated extension GeneralSettings {
    enum CodingKeys: String, CodingKey { case operatingMode, language, showMenuBarItem }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        operatingMode = c.value(.operatingMode, d.operatingMode)
        language = c.value(.language, d.language)
        showMenuBarItem = c.value(.showMenuBarItem, d.showMenuBarItem)
    }
}

nonisolated extension AppearanceSettings {
    enum CodingKeys: String, CodingKey {
        case theme, iconSize, magnificationEnabled, maxMagnification, transparency, border, spacing, animationsEnabled,
             showHoverLabels, showRunningIndicators
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        theme = c.value(.theme, d.theme)
        iconSize = c.value(.iconSize, d.iconSize)
        magnificationEnabled = c.value(.magnificationEnabled, d.magnificationEnabled)
        maxMagnification = c.value(.maxMagnification, d.maxMagnification)
        transparency = c.value(.transparency, d.transparency)
        border = c.value(.border, d.border)
        spacing = c.value(.spacing, d.spacing)
        animationsEnabled = c.value(.animationsEnabled, d.animationsEnabled)
        showHoverLabels = c.value(.showHoverLabels, d.showHoverLabels)
        showRunningIndicators = c.value(.showRunningIndicators, d.showRunningIndicators)
    }
}

nonisolated extension DockBehaviorSettings {
    enum CodingKeys: String, CodingKey { case autoHide, revealDelay, hideDelay, display, bottomMargin, avoidFullScreenApps, showTrash }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockBehaviorSettings()
        autoHide = c.value(.autoHide, d.autoHide)
        revealDelay = c.value(.revealDelay, d.revealDelay)
        hideDelay = c.value(.hideDelay, d.hideDelay)
        display = c.value(.display, d.display)
        bottomMargin = c.value(.bottomMargin, d.bottomMargin)
        avoidFullScreenApps = c.value(.avoidFullScreenApps, d.avoidFullScreenApps)
        showTrash = c.value(.showTrash, d.showTrash)
    }
}

nonisolated extension AgentSettings {
    enum CodingKeys: String, CodingKey {
        case enabled, quickPeekDelay, workingQuietLimitMinutes, toolQuietLimitMinutes, useSessionRegistry, showCompletionFlash, muted, pinned
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentSettings()
        enabled = c.value(.enabled, d.enabled)
        quickPeekDelay = c.value(.quickPeekDelay, d.quickPeekDelay)
        workingQuietLimitMinutes = c.value(.workingQuietLimitMinutes, d.workingQuietLimitMinutes)
        toolQuietLimitMinutes = c.value(.toolQuietLimitMinutes, d.toolQuietLimitMinutes)
        useSessionRegistry = c.value(.useSessionRegistry, d.useSessionRegistry)
        showCompletionFlash = c.value(.showCompletionFlash, d.showCompletionFlash)
        muted = c.value(.muted, d.muted)
        pinned = c.value(.pinned, d.pinned)
    }
}

nonisolated extension NotificationSettings {
    enum CodingKeys: String, CodingKey { case enabled, attention, failures, completions, usageLimits, playSound, quietHoursEnabled, quietStart, quietEnd }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        enabled = c.value(.enabled, d.enabled)
        attention = c.value(.attention, d.attention)
        failures = c.value(.failures, d.failures)
        completions = c.value(.completions, d.completions)
        usageLimits = c.value(.usageLimits, d.usageLimits)
        playSound = c.value(.playSound, d.playSound)
        quietHoursEnabled = c.value(.quietHoursEnabled, d.quietHoursEnabled)
        quietStart = c.value(.quietStart, d.quietStart)
        quietEnd = c.value(.quietEnd, d.quietEnd)
    }
}

nonisolated extension PrivacySettings {
    enum CodingKeys: String, CodingKey { case privacyMode, storeHistory, storePaths, retentionDays, commandDetail, keepFilePaths, keepSearchQueries }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrivacySettings()
        privacyMode = c.value(.privacyMode, d.privacyMode)
        storeHistory = c.value(.storeHistory, d.storeHistory)
        storePaths = c.value(.storePaths, d.storePaths)
        retentionDays = c.value(.retentionDays, d.retentionDays)
        commandDetail = c.value(.commandDetail, d.commandDetail)
        keepFilePaths = c.value(.keepFilePaths, d.keepFilePaths)
        keepSearchQueries = c.value(.keepSearchQueries, d.keepSearchQueries)
    }
}

nonisolated extension AdvancedSettings {
    enum CodingKeys: String, CodingKey { case demoMode, forceLegacyMaterial }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        demoMode = c.value(.demoMode, false)
        forceLegacyMaterial = c.value(.forceLegacyMaterial, false)
    }
}

nonisolated extension Workspace {
    enum CodingKeys: String, CodingKey {
        case id, name, symbol, pinned, theme, widgets, showRunningApps, agentFilter, preset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = c.value(.symbol, "square.grid.2x2")
        pinned = c.value(.pinned, [])
        theme = c.value(.theme, nil)
        widgets = c.value(.widgets, LossyArray<WidgetPlacement>(elements: [])).elements
        showRunningApps = c.value(.showRunningApps, true)
        agentFilter = c.value(.agentFilter, .all)
        preset = c.value(.preset, nil)
    }
}

extension LossyArray: Sendable where Element: Sendable {}
