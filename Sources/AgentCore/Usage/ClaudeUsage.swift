import Foundation

/// One usage window reported by Claude Code (Pro/Max): percent used and when it resets.
public struct UsageWindow: Codable, Hashable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date

    public init(usedPercent: Double, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Spend limit behind a Claude apps gateway. Dollar amounts may be absent.
public struct SpendWindow: Codable, Hashable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?
    public var usedUSD: Double?
    public var limitUSD: Double?
    public var period: String?

    public init(usedPercent: Double, resetsAt: Date?, usedUSD: Double?, limitUSD: Double?, period: String?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.usedUSD = usedUSD
        self.limitUSD = limitUSD
        self.period = period
    }
}

/// What one status line update of one Claude Code session says about usage. Only numbers,
/// the model and the project folder (see `StatusLineSanitizer`).
public struct ClaudeUsageSnapshot: Codable, Hashable, Sendable {
    public var sessionID: String
    public var observedAt: Date
    public var modelID: String?
    public var modelName: String?
    public var projectPath: String?
    public var version: String?
    /// Claude Code's client-side estimate at list price (not a bill).
    public var costUSD: Double?
    public var durationMS: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var contextUsedPercent: Double?
    public var contextSize: Int?
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var spend: SpendWindow?

    public init(sessionID: String, observedAt: Date, modelID: String? = nil, modelName: String? = nil, projectPath: String? = nil,
                version: String? = nil, costUSD: Double? = nil, durationMS: Double? = nil, linesAdded: Int? = nil, linesRemoved: Int? = nil,
                contextUsedPercent: Double? = nil, contextSize: Int? = nil, fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil,
                spend: SpendWindow? = nil) {
        self.sessionID = sessionID
        self.observedAt = observedAt
        self.modelID = modelID
        self.modelName = modelName
        self.projectPath = projectPath
        self.version = version
        self.costUSD = costUSD
        self.durationMS = durationMS
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.contextUsedPercent = contextUsedPercent
        self.contextSize = contextSize
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.spend = spend
    }

    public var hasLimits: Bool { fiveHour != nil || sevenDay != nil || spend != nil }
}

/// Account-level limits: the newest snapshot that carried them.
public struct UsageLimits: Codable, Hashable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var spend: SpendWindow?
    public var observedAt: Date

    /// Claude Code drops a window once it resets; so does PulseDock (a reset window is 0%,
    /// but the new one is only known after the next API response).
    public func current(now: Date) -> UsageLimits? {
        var copy = self
        if let window = copy.fiveHour, window.resetsAt <= now { copy.fiveHour = nil }
        if let window = copy.sevenDay, window.resetsAt <= now { copy.sevenDay = nil }
        if let reset = copy.spend?.resetsAt, reset <= now { copy.spend = nil }
        return copy.fiveHour == nil && copy.sevenDay == nil && copy.spend == nil ? nil : copy
    }
}

public struct DayUsage: Codable, Hashable, Sendable {
    public var costUSD: Double = 0
    public var linesAdded = 0
    public var linesRemoved = 0
    public var sessionIDs: [String] = []
    /// Sessions already running when PulseDock first saw them: their earlier cost is not
    /// attributed to any day, so the total is a lower bound.
    public var partial = false

    public init() {}
}

/// A threshold crossing worth a notification (once per window).
public struct UsageAlert: Hashable, Sendable {
    public enum Window: String, Sendable { case fiveHour, sevenDay, spend }
    public var window: Window
    public var threshold: Int
    public var usedPercent: Double
    public var resetsAt: Date?
}

/// Aggregates status line snapshots: limits, per-session usage, daily cost estimate and a
/// projection of when the 5-hour window runs out at the observed pace.
public struct ClaudeUsageLedger: Codable, Hashable, Sendable {
    public struct LimitSample: Codable, Hashable, Sendable {
        public var at: Date
        public var usedPercent: Double
        public var resetsAt: Date
    }

    public static let thresholds = [80, 95]

    public private(set) var limits: UsageLimits?
    public private(set) var sessions: [String: ClaudeUsageSnapshot] = [:]
    public private(set) var days: [String: DayUsage] = [:]
    public private(set) var fiveHourSamples: [LimitSample] = []
    private var alerted: [String] = []

    public init() {}

    public var lastObservedAt: Date? { sessions.values.map(\.observedAt).max() }

    /// Applies one snapshot; returns thresholds crossed by it.
    @discardableResult
    public mutating func apply(_ snapshot: ClaudeUsageSnapshot, calendar: Calendar = .current) -> [UsageAlert] {
        let previous = sessions[snapshot.sessionID]
        if let previous, previous.observedAt > snapshot.observedAt { return [] }
        let key = Self.dayKey(snapshot.observedAt, calendar: calendar)
        var day = days[key] ?? DayUsage()
        if !day.sessionIDs.contains(snapshot.sessionID), day.sessionIDs.count < 500 { day.sessionIDs.append(snapshot.sessionID) }
        if let previous {
            day.costUSD += Self.delta(snapshot.costUSD, previous.costUSD)
            day.linesAdded += Int(Self.delta(snapshot.linesAdded.map(Double.init), previous.linesAdded.map(Double.init)))
            day.linesRemoved += Int(Self.delta(snapshot.linesRemoved.map(Double.init), previous.linesRemoved.map(Double.init)))
        } else if (snapshot.durationMS ?? 0) <= 15 * 60_000 {
            // A new session: everything it reports happened now.
            day.costUSD += snapshot.costUSD ?? 0
            day.linesAdded += snapshot.linesAdded ?? 0
            day.linesRemoved += snapshot.linesRemoved ?? 0
        } else {
            day.partial = true
        }
        days[key] = day
        sessions[snapshot.sessionID] = snapshot

        guard snapshot.hasLimits, snapshot.observedAt >= (limits?.observedAt ?? .distantPast) else { return [] }
        limits = UsageLimits(fiveHour: snapshot.fiveHour, sevenDay: snapshot.sevenDay, spend: snapshot.spend, observedAt: snapshot.observedAt)
        if let window = snapshot.fiveHour {
            fiveHourSamples.removeAll { $0.resetsAt != window.resetsAt }
            fiveHourSamples.append(LimitSample(at: snapshot.observedAt, usedPercent: window.usedPercent, resetsAt: window.resetsAt))
            if fiveHourSamples.count > 64 { fiveHourSamples.removeFirst(fiveHourSamples.count - 64) }
        }
        var alerts: [UsageAlert] = []
        func check(_ window: UsageAlert.Window, _ percent: Double?, _ reset: Date?) {
            guard let percent else { return }
            for threshold in Self.thresholds where percent >= Double(threshold) {
                let id = "\(window.rawValue)-\(Int(reset?.timeIntervalSince1970 ?? 0))-\(threshold)"
                guard !alerted.contains(id) else { continue }
                alerted.append(id)
                // Only the highest threshold crossed by this update is announced.
                alerts.removeAll { $0.window == window }
                alerts.append(UsageAlert(window: window, threshold: threshold, usedPercent: percent, resetsAt: reset))
            }
        }
        check(.fiveHour, snapshot.fiveHour?.usedPercent, snapshot.fiveHour?.resetsAt)
        check(.sevenDay, snapshot.sevenDay?.usedPercent, snapshot.sevenDay?.resetsAt)
        check(.spend, snapshot.spend?.usedPercent, snapshot.spend?.resetsAt)
        if alerted.count > 64 { alerted.removeFirst(alerted.count - 64) }
        return alerts
    }

    /// Increase since the previous report; a smaller value means the counter restarted.
    static func delta(_ current: Double?, _ previous: Double?) -> Double {
        guard let current else { return 0 }
        guard let previous else { return current }
        return current >= previous ? current - previous : current
    }

    public func currentLimits(now: Date) -> UsageLimits? { limits?.current(now: now) }

    /// When the 5-hour window would reach 100% at the pace observed in the last 90 minutes,
    /// if that happens before it resets. Needs at least 10 minutes and one point of growth;
    /// otherwise nil (no projection is shown).
    public func fiveHourExhaustion(now: Date) -> Date? {
        guard let window = currentLimits(now: now)?.fiveHour, window.usedPercent < 100 else { return nil }
        let recent = fiveHourSamples.filter { $0.resetsAt == window.resetsAt && now.timeIntervalSince($0.at) <= 90 * 60 }
        guard let first = recent.first, let last = recent.last else { return nil }
        let elapsed = last.at.timeIntervalSince(first.at)
        let growth = last.usedPercent - first.usedPercent
        guard elapsed >= 600, growth >= 1 else { return nil }
        let eta = last.at.addingTimeInterval((100 - last.usedPercent) / (growth / elapsed))
        return eta < window.resetsAt ? eta : nil
    }

    public func day(_ date: Date, calendar: Calendar = .current) -> DayUsage {
        days[Self.dayKey(date, calendar: calendar)] ?? DayUsage()
    }

    /// Sessions reported recently, newest first.
    public func recentSessions(now: Date, within interval: TimeInterval = 6 * 3600) -> [ClaudeUsageSnapshot] {
        sessions.values.filter { now.timeIntervalSince($0.observedAt) <= interval }.sorted { $0.observedAt > $1.observedAt }
    }

    /// Keeps 35 days of totals and one day of sessions.
    public mutating func prune(now: Date, calendar: Calendar = .current) {
        let cutoff = Self.dayKey(now.addingTimeInterval(-35 * 86_400), calendar: calendar)
        days = days.filter { $0.key >= cutoff }
        sessions = sessions.filter { now.timeIntervalSince($0.value.observedAt) <= 86_400 }
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
