import AppKit
import DockRendering
import WidgetCore

/// Groups of the "Add Widget" menus.
enum WidgetCategory: String, CaseIterable {
    case ai, time, productivity, files, utilities, system, media

    var displayName: String {
        switch self {
        case .ai: tr("widget.category.ai", "AI Agents")
        case .time: tr("widget.category.time", "Time")
        case .productivity: tr("widget.category.productivity", "Productivity")
        case .files: tr("widget.category.files", "Files")
        case .utilities: tr("widget.category.utilities", "Utilities")
        case .system: tr("widget.category.system", "System")
        case .media: tr("widget.category.media", "Media")
        }
    }

    var symbol: String {
        switch self {
        case .ai: "sparkles"
        case .time: "clock"
        case .productivity: "checklist"
        case .files: "folder"
        case .utilities: "wrench.and.screwdriver"
        case .system: "gauge.with.dots.needle.33percent"
        case .media: "play.rectangle"
        }
    }
}

/// How wide a tile is, in icon widths: square for a number, wide when it has more to say.
enum WidgetWidth {
    case square, medium, wide, extraWide

    var factor: Double {
        switch self {
        case .square: 1.0
        case .medium: 1.45
        case .wide: 2.3
        case .extraWide: 2.9
        }
    }
}

extension WidgetKind {
    var displayName: String {
        switch self {
        case .clock: tr("widget.clock", "Clock")
        case .systemHealth: tr("widget.systemHealth", "System Health")
        case .nowPlaying: tr("widget.nowPlaying", "Now Playing")
        case .quickLaunch: tr("widget.quickLaunch", "Quick Launch")
        case .calendar: tr("widget.calendar", "Calendar")
        case .timer: tr("widget.timer", "Timer")
        case .stopwatch: tr("widget.stopwatch", "Stopwatch")
        case .pomodoro: tr("widget.pomodoro", "Pomodoro")
        case .countdown: tr("widget.countdown", "Countdown")
        case .timeProgress: tr("widget.timeProgress", "Time Progress")
        case .reminders: tr("widget.reminders", "Reminders")
        case .note: tr("widget.note", "Note")
        case .shortcuts: tr("widget.shortcuts", "Shortcuts")
        case .water: tr("widget.water", "Water")
        case .files: tr("widget.files", "Downloads")
        case .shelf: tr("widget.shelf", "Shelf")
        case .airDrop: tr("widget.airDrop", "AirDrop")
        case .screenshots: tr("widget.screenshots", "Screenshots")
        case .clipboard: tr("widget.clipboard", "Clipboard")
        case .colorPicker: tr("widget.colorPicker", "Color Picker")
        case .emoji: tr("widget.emoji", "Emoji")
        case .converter: tr("widget.converter", "Converter")
        case .network: tr("widget.network", "Network")
        case .battery: tr("widget.battery", "Battery")
        case .weather: tr("widget.weather", "Weather")
        case .cinema: tr("widget.cinema", "Dock Cinema")
        case .agentHeartbeat: tr("widget.agentHeartbeat", "Agent Heartbeat")
        case .pulseBuddy: tr("widget.pulseBuddy", "Pulse Buddy")
        case .claudeUsage: tr("widget.claudeUsage", "Claude Usage")
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock"
        case .systemHealth: "cpu"
        case .nowPlaying: "music.note"
        case .quickLaunch: "square.grid.2x2"
        case .calendar: "calendar"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        case .pomodoro: "circle.circle"
        case .countdown: "hourglass"
        case .timeProgress: "chart.bar.fill"
        case .reminders: "checklist"
        case .note: "note.text"
        case .shortcuts: "square.2.layers.3d"
        case .water: "drop.fill"
        case .files: "arrow.down.circle"
        case .shelf: "tray.full"
        case .airDrop: "airplayaudio"
        case .screenshots: "camera.viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .colorPicker: "eyedropper"
        case .emoji: "face.smiling"
        case .converter: "arrow.left.arrow.right"
        case .network: "network"
        case .battery: "battery.75percent"
        case .weather: "cloud.sun"
        case .cinema: "play.rectangle.on.rectangle"
        case .agentHeartbeat: "waveform.path.ecg"
        case .pulseBuddy: "face.smiling.inverse"
        case .claudeUsage: "gauge.with.needle"
        }
    }

    var category: WidgetCategory {
        switch self {
        case .agentHeartbeat, .pulseBuddy, .claudeUsage: .ai
        case .clock, .calendar, .timer, .stopwatch, .pomodoro, .countdown, .timeProgress: .time
        case .reminders, .note, .shortcuts, .water, .quickLaunch: .productivity
        case .files, .shelf, .airDrop, .screenshots: .files
        case .clipboard, .colorPicker, .emoji, .converter: .utilities
        case .systemHealth, .network, .battery, .weather: .system
        case .nowPlaying, .cinema: .media
        }
    }

    /// One-line description shown in the Add Widget menus' tooltips and in Settings.
    var summary: String {
        switch self {
        case .clock: tr("widget.clock.summary", "Local time or another time zone, digital or analog.")
        case .systemHealth: tr("widget.systemHealth.summary", "CPU, memory and battery at a glance.")
        case .nowPlaying: tr("widget.nowPlaying.summary", "What Music or Spotify is playing, with controls.")
        case .quickLaunch: tr("widget.quickLaunch.summary", "A grid of apps, folders and files.")
        case .calendar: tr("widget.calendar.summary", "Today's date, your next event and a join button for calls.")
        case .timer: tr("widget.timer.summary", "A countdown with a progress ring on the tile.")
        case .stopwatch: tr("widget.stopwatch.summary", "Counts up, with laps.")
        case .pomodoro: tr("widget.pomodoro.summary", "Focus and break cycles with a daily goal.")
        case .countdown: tr("widget.countdown.summary", "Days left until a date that matters.")
        case .timeProgress: tr("widget.timeProgress.summary", "How much of the day, week, month or year has passed.")
        case .reminders: tr("widget.reminders.summary", "What is due next; tick items off from the dock.")
        case .note: tr("widget.note.summary", "A note that stays on the dock.")
        case .shortcuts: tr("widget.shortcuts.summary", "Run any shortcut from the Shortcuts app.")
        case .water: tr("widget.water.summary", "Track the glasses of water you drink each day.")
        case .files: tr("widget.files.summary", "Your newest downloads (or any folder), with a count of new items.")
        case .shelf: tr("widget.shelf.summary", "Park files while you drag them between places.")
        case .airDrop: tr("widget.airDrop.summary", "Drop files to send them with AirDrop.")
        case .screenshots: tr("widget.screenshots.summary", "Your latest screenshots, ready to drag.")
        case .clipboard: tr("widget.clipboard.summary", "What you copied recently, with pinning. Kept in memory only.")
        case .colorPicker: tr("widget.colorPicker.summary", "Pick a color anywhere on screen and copy it.")
        case .emoji: tr("widget.emoji.summary", "Your most used emoji, one click away.")
        case .converter: tr("widget.converter.summary", "Length, weight, temperature, data and more.")
        case .network: tr("widget.network.summary", "Live download and upload speed.")
        case .battery: tr("widget.battery.summary", "Charge and time remaining.")
        case .weather: tr("widget.weather.summary", "Forecast for a city you choose.")
        case .cinema: tr("widget.cinema.summary", "YouTube in a floating player that pauses when an agent needs you.")
        case .agentHeartbeat: tr("widget.agentHeartbeat.summary", "A live ECG of your agents and the result of their test runs.")
        case .pulseBuddy: tr("widget.pulseBuddy.summary", "A small companion that reacts to what your agents are doing.")
        case .claudeUsage: tr("widget.claudeUsage.summary", "Your Claude 5-hour and weekly limits, session cost and context, from Claude Code.")
        }
    }

    var width: WidgetWidth {
        switch self {
        case .clock, .systemHealth, .network, .weather, .claudeUsage: .medium
        case .nowPlaying, .cinema: .extraWide
        case .agentHeartbeat, .note: .wide
        default: .square
        }
    }

    /// Widgets offered by the Add Widget menus (Quick Launch is added per collection).
    static var addable: [WidgetKind] { allCases.filter { $0 != .quickLaunch } }

    /// Whether the widget accepts things dropped on its tile.
    var acceptsDrops: Bool {
        switch self {
        case .airDrop, .shelf, .cinema, .note: true
        default: false
        }
    }
}
