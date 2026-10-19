import AppKit
import EventKit
import Observation

public nonisolated struct CalendarEventSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarColor: NSColor?
    public var location: String?
    public var hasVideoCall: Bool
    public var videoCallURL: URL?
}

public nonisolated struct ReminderSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var due: Date?
    public var listName: String?
    public var listColor: NSColor?
    public var priority: Int
}

/// Calendar and Reminders through EventKit. Access is requested only when the user opens or
/// adds one of these widgets; the macOS prompt explains why. Changes arrive through
/// `EKEventStoreChanged` (no polling).
@Observable
public final class EventKitProvider {
    public enum Access: Sendable { case unknown, granted, denied }

    public private(set) var calendarAccess: Access = .unknown
    public private(set) var remindersAccess: Access = .unknown
    public private(set) var events: [CalendarEventSummary] = []
    public private(set) var reminders: [ReminderSummary] = []
    public private(set) var now = Date()
    public var wantsCalendar = false {
        didSet { if wantsCalendar != oldValue { refresh() } }
    }
    public var wantsReminders = false {
        didSet { if wantsReminders != oldValue { refresh() } }
    }

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var dayTimer: Timer?

    public init() {
        calendarAccess = Self.map(EKEventStore.authorizationStatus(for: .event))
        remindersAccess = Self.map(EKEventStore.authorizationStatus(for: .reminder))
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        scheduleMinuteTick()
    }

    private static func map(_ status: EKAuthorizationStatus) -> Access {
        switch status {
        case .fullAccess, .authorized: .granted
        case .denied, .restricted, .writeOnly: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    /// Keeps "in 5 min" labels and the tile's date current: one tick per minute.
    private func scheduleMinuteTick() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsCalendar || self.wantsReminders else { return }
                self.now = Date()
                if Calendar.current.component(.minute, from: self.now) == 0 { self.refresh() }
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        dayTimer = timer
    }

    public func requestCalendarAccess() {
        Task { @MainActor in
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            calendarAccess = granted ? .granted : .denied
            refresh()
        }
    }

    public func requestRemindersAccess() {
        Task { @MainActor in
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            remindersAccess = granted ? .granted : .denied
            refresh()
        }
    }

    public func refresh() {
        now = Date()
        if wantsCalendar, calendarAccess == .granted { loadEvents() }
        if wantsReminders, remindersAccess == .granted { loadReminders() }
    }

    private func loadEvents() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.endDate > now || $0.isAllDay && calendar.isDateInToday($0.startDate) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(30)
            .map { event in
                let call = Self.videoCallURL(in: event)
                return CalendarEventSummary(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarColor: event.calendar?.color,
                    location: event.location,
                    hasVideoCall: call != nil,
                    videoCallURL: call
                )
            }
    }

    /// Meeting links commonly found in the event URL, location or notes.
    static func videoCallURL(in event: EKEvent) -> URL? {
        let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "facetime.apple.com", "webex.com", "whereby.com"]
        let candidates = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in candidates {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, let host = url.host?.lowercased(), hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }

    private func loadReminders() {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] result in
            let mapped: [ReminderSummary] = (result ?? []).map { reminder in
                ReminderSummary(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "",
                    due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                    listName: reminder.calendar?.title,
                    listColor: reminder.calendar?.color,
                    priority: reminder.priority
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.due, rhs.due) {
                case let (l?, r?): l < r
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.title < rhs.title
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reminders = Array(mapped.prefix(40)) }
            }
        }
    }

    /// Marks a reminder complete (the user clicked its checkbox).
    public func complete(_ reminder: ReminderSummary) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        try? store.save(item, commit: true)
        reminders.removeAll { $0.id == reminder.id }
    }

    /// Adds a reminder to the default list.
    public func addReminder(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, remindersAccess == .granted, let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = list
        try? store.save(reminder, commit: true)
        refresh()
    }

    public var todayEvents: [CalendarEventSummary] {
        events.filter { Calendar.current.isDate($0.start, inSameDayAs: now) || ($0.start < now && $0.end > now) }
    }

    public var nextEvent: CalendarEventSummary? {
        events.first { !$0.isAllDay && $0.end > now }
    }
}
