import Foundation
import Observation

// MARK: - Pure state machines (the clock is always injected, so they are deterministic)

/// A countdown timer that can be paused and resumed.
public nonisolated struct CountdownTimer: Codable, Hashable, Sendable {
    public private(set) var duration: TimeInterval
    /// Remaining time frozen while paused or idle.
    private var remainingAtPause: TimeInterval
    /// When running: the moment the timer reaches zero.
    private var endsAt: Date?

    public init(duration: TimeInterval) {
        self.duration = max(1, duration)
        remainingAtPause = max(1, duration)
    }

    public var isRunning: Bool { endsAt != nil }

    public func remaining(at now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return remainingAtPause
    }

    /// 0 at start, 1 when finished.
    public func progress(at now: Date) -> Double {
        1 - remaining(at: now) / duration
    }

    public func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }

    public mutating func start(at now: Date) {
        guard endsAt == nil else { return }
        if remainingAtPause <= 0 { remainingAtPause = duration }
        endsAt = now.addingTimeInterval(remainingAtPause)
    }

    public mutating func pause(at now: Date) {
        guard let endsAt else { return }
        remainingAtPause = max(0, endsAt.timeIntervalSince(now))
        self.endsAt = nil
    }

    public mutating func reset(duration newDuration: TimeInterval? = nil) {
        if let newDuration { duration = max(1, newDuration) }
        remainingAtPause = duration
        endsAt = nil
    }
}

/// A stopwatch with laps.
public nonisolated struct Stopwatch: Codable, Hashable, Sendable {
    private var accumulated: TimeInterval = 0
    private var startedAt: Date?
    /// Lap split times (elapsed at the moment the lap was taken).
    public private(set) var laps: [TimeInterval] = []

    public init() {}

    public var isRunning: Bool { startedAt != nil }

    public func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    public mutating func start(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    public mutating func pause(at now: Date) {
        guard startedAt != nil else { return }
        accumulated = elapsed(at: now)
        startedAt = nil
    }

    public mutating func lap(at now: Date) {
        guard isRunning else { return }
        laps.append(elapsed(at: now))
    }

    public mutating func reset() {
        self = Stopwatch()
    }

    /// Duration of each lap (difference between consecutive splits), newest first.
    public var lapDurations: [TimeInterval] {
        var previous: TimeInterval = 0
        var result: [TimeInterval] = []
        for split in laps {
            result.append(split - previous)
            previous = split
        }
        return result.reversed()
    }
}

/// Pomodoro cycle: focus, short break, and a long break after every N focus sessions.
public nonisolated struct PomodoroCycle: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case focus
        case shortBreak
        case longBreak
    }

    public struct Configuration: Codable, Hashable, Sendable {
        public var focus: TimeInterval = 25 * 60
        public var shortBreak: TimeInterval = 5 * 60
        public var longBreak: TimeInterval = 15 * 60
        public var focusesBeforeLongBreak = 4
        public var dailyGoal = 8

        public init() {}
    }

    public var configuration: Configuration
    public private(set) var phase: Phase = .focus
    public private(set) var timer: CountdownTimer
    /// Focus sessions completed in the current set (resets after a long break).
    public private(set) var focusesInSet = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        timer = CountdownTimer(duration: configuration.focus)
    }

    public func duration(of phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: configuration.focus
        case .shortBreak: configuration.shortBreak
        case .longBreak: configuration.longBreak
        }
    }

    public mutating func start(at now: Date) { timer.start(at: now) }
    public mutating func pause(at now: Date) { timer.pause(at: now) }

    /// Moves to the next phase. Returns true when a focus session was completed.
    @discardableResult
    public mutating func advance(completed: Bool) -> Bool {
        let finishedFocus = phase == .focus && completed
        switch phase {
        case .focus:
            if completed { focusesInSet += 1 }
            phase = focusesInSet >= configuration.focusesBeforeLongBreak ? .longBreak : .shortBreak
        case .shortBreak:
            phase = .focus
        case .longBreak:
            focusesInSet = 0
            phase = .focus
        }
        timer = CountdownTimer(duration: duration(of: phase))
        return finishedFocus
    }

    public mutating func reset() {
        phase = .focus
        focusesInSet = 0
        timer = CountdownTimer(duration: configuration.focus)
    }
}

// MARK: - Calendar maths

public nonisolated enum TimeProgressScope: String, Codable, Sendable, CaseIterable {
    case day, week, month, year
}

public nonisolated enum TimeMath {
    /// Fraction of the day/week/month/year elapsed at `now`.
    public static func progress(_ scope: TimeProgressScope, at now: Date, calendar: Calendar = .current) -> Double {
        let component: Calendar.Component = switch scope {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        guard let interval = calendar.dateInterval(of: component, for: now), interval.duration > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(interval.start) / interval.duration))
    }

    /// Whole calendar days from `now` to `target` (0 when it is today, negative when past).
    public static func daysUntil(_ target: Date, from now: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: target)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// "05:07" or "1:02:07".
    public static func clock(_ interval: TimeInterval, tenths: Bool = false) -> String {
        let total = max(0, interval)
        let seconds = Int(total)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        var text = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
        if tenths { text += String(format: ".%d", Int((total - Double(seconds)) * 10)) }
        return text
    }

    /// Key for per-day counters ("2026-10-18" in the user's calendar).
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - Live provider

/// Owns the timer, stopwatch and Pomodoro shown in the dock. Ticks once per second only while
/// one of them runs (and ten times per second while a stopwatch panel is open).
@Observable
public final class FocusTimersProvider {
    public var timer = CountdownTimer(duration: 5 * 60)
    public var stopwatch = Stopwatch()
    public var pomodoro = PomodoroCycle()
    public private(set) var now = Date()
    /// Called when a countdown or Pomodoro phase reaches zero.
    @ObservationIgnored public var onFinished: (_ title: String, _ isPomodoroFocus: Bool) -> Void = { _, _ in }
    /// Completed Pomodoro focus sessions per day (persisted by the app).
    public var completedFocusByDay: [String: Int] = [:]
    public var highFrequency = false {
        didSet { if highFrequency != oldValue { reschedule() } }
    }

    @ObservationIgnored private var ticker: Timer?

    public init() {}

    public var anyRunning: Bool { timer.isRunning || stopwatch.isRunning || pomodoro.timer.isRunning }

    public var focusToday: Int { completedFocusByDay[TimeMath.dayKey(now)] ?? 0 }

    public func toggleTimer() {
        let now = Date()
        if timer.isRunning { timer.pause(at: now) } else { timer.start(at: now) }
        changed()
    }

    public func setTimer(minutes: Double) {
        timer.reset(duration: minutes * 60)
        timer.start(at: Date())
        changed()
    }

    public func resetTimer() {
        timer.reset()
        changed()
    }

    public func toggleStopwatch() {
        let now = Date()
        if stopwatch.isRunning { stopwatch.pause(at: now) } else { stopwatch.start(at: now) }
        changed()
    }

    public func lap() {
        stopwatch.lap(at: Date())
        changed()
    }

    public func resetStopwatch() {
        stopwatch.reset()
        changed()
    }

    public func togglePomodoro() {
        let now = Date()
        if pomodoro.timer.isRunning { pomodoro.pause(at: now) } else { pomodoro.start(at: now) }
        changed()
    }

    public func skipPomodoroPhase() {
        pomodoro.advance(completed: false)
        changed()
    }

    public func resetPomodoro() {
        pomodoro.reset()
        changed()
    }

    private func changed() {
        now = Date()
        reschedule()
    }

    private func reschedule() {
        ticker?.invalidate()
        ticker = nil
        guard anyRunning else { return }
        let interval = highFrequency && stopwatch.isRunning ? 0.1 : 1
        let ticker = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker.tolerance = interval * 0.2
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func tick() {
        now = Date()
        if timer.isRunning, timer.isFinished(at: now) {
            timer.reset()
            onFinished("timer", false)
        }
        if pomodoro.timer.isRunning, pomodoro.timer.isFinished(at: now) {
            let wasFocus = pomodoro.phase == .focus
            if pomodoro.advance(completed: true) {
                completedFocusByDay[TimeMath.dayKey(now), default: 0] += 1
            }
            onFinished("pomodoro", wasFocus)
            // The next phase starts automatically, like a physical Pomodoro timer.
            pomodoro.start(at: now)
        }
        if !anyRunning { reschedule() }
    }
}
