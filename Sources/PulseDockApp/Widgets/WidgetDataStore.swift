import AgentCore
import Foundation
import Observation
import Persistence
import WidgetCore

/// What widgets remember between launches (notes, water log, Pomodoro history, the Dock
/// Cinema queue…). Stored in the same SQLite settings table as `AppSettings`, under its own
/// key, so typing a note never rebuilds the dock.
nonisolated struct WidgetData: Codable, Hashable, Sendable {
    var notes: [String: String] = [:]
    /// Glasses per day ("2026-10-18" → 5).
    var water: [String: Int] = [:]
    var pomodoroFocusByDay: [String: Int] = [:]
    var pinnedClipboard: [String] = []
    var emojiUsage: [String: Int] = [:]
    var emojiTone = 0
    var recentColors: [String] = []
    /// Shelf items are references to files that stay where they are.
    var shelf: [String] = []
    var filesLastSeen: [String: Date] = [:]
    var cinemaQueue: [YouTubeVideo] = []
    var cinemaCurrent: YouTubeVideo?
    var cinemaPauseForAgents = true
    var cinemaResumeAfterAgents = false
    var cinemaFrame: [Double]?
    /// Off until the user asks Dock Cinema to look for YouTube tabs (Automation consent).
    var cinemaBrowserDetection = false
    var timerMinutes: Double = 5
    /// Claude usage from the status line: numbers only (limits, daily cost estimate).
    var claudeUsage = ClaudeUsageLedger()

    init() {}

    enum CodingKeys: String, CodingKey {
        case notes, water, pomodoroFocusByDay, pinnedClipboard, emojiUsage, emojiTone, recentColors, shelf, filesLastSeen,
             cinemaQueue, cinemaCurrent, cinemaPauseForAgents, cinemaResumeAfterAgents, cinemaFrame, cinemaBrowserDetection, timerMinutes, claudeUsage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WidgetData()
        notes = c.value(.notes, d.notes)
        water = c.value(.water, d.water)
        pomodoroFocusByDay = c.value(.pomodoroFocusByDay, d.pomodoroFocusByDay)
        pinnedClipboard = c.value(.pinnedClipboard, d.pinnedClipboard)
        emojiUsage = c.value(.emojiUsage, d.emojiUsage)
        emojiTone = c.value(.emojiTone, d.emojiTone)
        recentColors = c.value(.recentColors, d.recentColors)
        shelf = c.value(.shelf, d.shelf)
        filesLastSeen = c.value(.filesLastSeen, d.filesLastSeen)
        cinemaQueue = c.value(.cinemaQueue, d.cinemaQueue)
        cinemaCurrent = c.value(.cinemaCurrent, d.cinemaCurrent)
        cinemaPauseForAgents = c.value(.cinemaPauseForAgents, d.cinemaPauseForAgents)
        cinemaResumeAfterAgents = c.value(.cinemaResumeAfterAgents, d.cinemaResumeAfterAgents)
        cinemaFrame = c.value(.cinemaFrame, d.cinemaFrame)
        cinemaBrowserDetection = c.value(.cinemaBrowserDetection, d.cinemaBrowserDetection)
        timerMinutes = c.value(.timerMinutes, d.timerMinutes)
        claudeUsage = c.value(.claudeUsage, d.claudeUsage)
    }

    /// Keeps per-day logs bounded (one year).
    mutating func prune(now: Date = Date()) {
        let cutoff = TimeMath.dayKey(now.addingTimeInterval(-366 * 86_400))
        water = water.filter { $0.key >= cutoff }
        pomodoroFocusByDay = pomodoroFocusByDay.filter { $0.key >= cutoff }
    }
}

@Observable
final class WidgetDataStore {
    var data: WidgetData {
        didSet { if data != oldValue { scheduleSave() } }
    }

    @ObservationIgnored private let persistence: PersistenceController?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    static let key = "widgets.data.v1"

    init(persistence: PersistenceController?) {
        self.persistence = persistence
        var loaded = persistence?.loadSetting(WidgetData.self, key: WidgetDataStore.key) ?? WidgetData()
        loaded.prune()
        data = loaded
    }

    func update(_ change: (inout WidgetData) -> Void) {
        var copy = data
        change(&copy)
        data = copy
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        persistence?.saveSetting(data, key: WidgetDataStore.key)
    }
}
