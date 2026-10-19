import Foundation
import Observation

/// Current time, updated exactly at minute boundaries (or every second when seconds are
/// shown and the widget is visible).
@Observable
public final class ClockProvider {
    public private(set) var now = Date()
    public var showsSeconds = false {
        didSet { if showsSeconds != oldValue { reschedule() } }
    }
    public var isVisible = true {
        didSet { if isVisible != oldValue { reschedule() } }
    }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init() {
        reschedule()
        // Clock changes, time zone changes and wake from sleep all need an immediate update.
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reschedule() }
            })
        }
    }

    private func reschedule() {
        timer?.invalidate()
        now = Date()
        guard isVisible else { return }
        let interval: TimeInterval = showsSeconds ? 1 : 60
        let next = showsSeconds
            ? now.addingTimeInterval(1 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1))
            : Calendar.current.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fire: next, interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        timer.tolerance = showsSeconds ? 0.05 : 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
