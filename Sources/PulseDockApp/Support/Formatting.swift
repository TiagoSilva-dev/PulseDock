import Foundation

enum Formatting {
    /// "agora", "há 2 min", "há 3 h" — compact relative times for cards and timelines.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 10 { return tr("time.now", "just now") }
        if seconds < 60 { return tr("time.secondsAgo", "%ld s ago", Int(seconds)) }
        if seconds < 3600 { return tr("time.minutesAgo", "%ld min ago", Int(seconds / 60)) }
        if seconds < 86_400 { return tr("time.hoursAgo", "%ld h ago", Int(seconds / 3600)) }
        return tr("time.daysAgo", "%ld d ago", Int(seconds / 86_400))
    }

    /// "4 min", "1 h 12 min", "38 s" — durations.
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        if seconds < 60 { return tr("duration.seconds", "%ld s", seconds) }
        if seconds < 3600 { return tr("duration.minutes", "%ld min", seconds / 60) }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? tr("duration.hours", "%ld h", hours) : tr("duration.hoursMinutes", "%ld h %ld min", hours, minutes)
    }

    /// "41%" in the current locale (whole percent).
    static func percent(_ fraction: Double) -> String {
        percentFormatter.string(from: NSNumber(value: fraction)) ?? "\(Int((fraction * 100).rounded()))%"
    }

    static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// US dollars in the current locale ("US$ 1,75", "$1.75"): Claude Code estimates in USD.
    static func usd(_ value: Double) -> String {
        usdFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    /// When a limit resets: "15:40 (in 1 h 12 min)" today, "Fri 09:00" later.
    static func reset(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) || date.timeIntervalSince(now) < 12 * 3600 {
            return tr("usage.resetSoon", "%@ (in %@)", timeFormatter.string(from: date), duration(date.timeIntervalSince(now)))
        }
        return weekdayTimeFormatter.string(from: date)
    }

    static let weekdayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let timeWithSecondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm:ss")
        return formatter
    }()

    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// "21:37" today, "18 Oct, 21:37" this year, "18 Oct 2025" before — fits a narrow column.
    static func compactDateTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return timeFormatter.string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return dayMonthTimeFormatter.string(from: date)
        }
        return dayMonthYearFormatter.string(from: date)
    }

    static let dayMonthTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMMjmm")
        return formatter
    }()

    static let dayMonthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return formatter
    }()

    /// Abbreviates a path under the home directory as `~/…` and keeps the last components.
    static func shortPath(_ path: String?, components: Int = 3) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        let display = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = display.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > components else { return display }
        return "…/" + parts.suffix(components).joined(separator: "/")
    }
}
