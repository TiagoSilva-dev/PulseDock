import AppKit
import DockRendering
import SwiftUI
import WidgetCore

// MARK: - Clock (local or another time zone, digital or analog)

extension WidgetOptions {
    var timeZone: TimeZone { timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current }
    var isOtherTimeZone: Bool { timeZoneID != nil && timeZoneID != TimeZone.current.identifier }
}

enum ClockText {
    static func time(_ date: Date, in zone: TimeZone, seconds: Bool = false) -> String {
        var style = seconds ? Date.FormatStyle.dateTime.hour().minute().second() : Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = zone
        return date.formatted(style)
    }

    static func weekdayDay(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day()
        style.timeZone = zone
        return date.formatted(style)
    }

    /// "São Paulo", "Tokyo" from "America/Sao_Paulo".
    static func city(_ zone: TimeZone) -> String {
        let last = zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// "+3 h" relative to the Mac's time zone.
    static func offset(_ zone: TimeZone, at date: Date) -> String {
        let difference = Double(zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)) / 3600
        if difference == 0 { return tr("clock.sameTime", "Same time") }
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.positivePrefix = "+"
        return tr("clock.offset", "%@ h", formatter.string(from: NSNumber(value: difference)) ?? "\(difference)")
    }
}

struct ClockTile: View {
    let clock: ClockProvider
    let options: WidgetOptions
    let theme: Theme

    var body: some View {
        let zone = options.timeZone
        Group {
            if options.analogClock == true {
                AnalogClock(date: clock.now, zone: zone, theme: theme, showsSeconds: false)
                    .padding(5)
            } else {
                VStack(spacing: 1) {
                    Text(ClockText.time(clock.now, in: zone))
                        .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(options.isOtherTimeZone ? ClockText.city(zone) : ClockText.weekdayDay(clock.now, in: zone))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(options.isOtherTimeZone ? nil : .uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .foregroundStyle(theme.labelText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(options.isOtherTimeZone ? ClockText.city(zone) : tr("widget.clock", "Clock"))
        .accessibilityValue(ClockText.time(clock.now, in: zone))
    }
}

/// An original analog face: hour ticks, rounded hands, accent second hand when shown.
struct AnalogClock: View {
    let date: Date
    let zone: TimeZone
    let theme: Theme
    let showsSeconds: Bool

    var body: some View {
        Canvas { context, size in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let face = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(face, with: .color(Color.primary.opacity(0.07)))
            context.stroke(face, with: .color(Color.primary.opacity(0.18)), lineWidth: 0.8)
            for tick in 0..<12 {
                let angle = Double(tick) / 12 * 2 * .pi
                let inner = radius * (tick % 3 == 0 ? 0.74 : 0.82)
                var path = Path()
                path.move(to: CGPoint(x: center.x + sin(angle) * inner, y: center.y - cos(angle) * inner))
                path.addLine(to: CGPoint(x: center.x + sin(angle) * radius * 0.9, y: center.y - cos(angle) * radius * 0.9))
                context.stroke(path, with: .color(Color.primary.opacity(tick % 3 == 0 ? 0.55 : 0.28)), style: StrokeStyle(lineWidth: tick % 3 == 0 ? 1.4 : 0.9, lineCap: .round))
            }
            let minute = Double(parts.minute ?? 0) + Double(parts.second ?? 0) / 60
            let hour = Double((parts.hour ?? 0) % 12) + minute / 60
            func hand(_ fraction: Double, length: Double, width: Double, color: Color) {
                let angle = fraction * 2 * .pi
                var path = Path()
                path.move(to: CGPoint(x: center.x - sin(angle) * radius * 0.1, y: center.y + cos(angle) * radius * 0.1))
                path.addLine(to: CGPoint(x: center.x + sin(angle) * radius * length, y: center.y - cos(angle) * radius * length))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand(hour / 12, length: 0.5, width: max(2, radius * 0.11), color: .primary)
            hand(minute / 60, length: 0.74, width: max(1.5, radius * 0.07), color: .primary)
            if showsSeconds {
                hand(Double(parts.second ?? 0) / 60, length: 0.8, width: 1, color: theme.tone(.attention))
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(theme.tone(.attention)))
        }
        .accessibilityHidden(true)
    }
}

struct ClockPanel: View {
    let clock: ClockProvider
    let options: WidgetOptions
    let theme: Theme
    let accessibility: AccessibilityOptions
    let update: (WidgetOptions) -> Void
    @State private var query = ""
    @State private var choosingZone = false

    var body: some View {
        let zone = options.timeZone
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: options.isOtherTimeZone ? ClockText.city(zone) : tr("widget.clock", "Clock")) {
            HStack(alignment: .center, spacing: 14) {
                if options.analogClock == true {
                    AnalogClock(date: clock.now, zone: zone, theme: theme, showsSeconds: true).frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ClockText.time(clock.now, in: zone, seconds: true))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(fullDate(zone)).font(PulseTypography.panelBody).foregroundStyle(.secondary)
                    if options.isOtherTimeZone {
                        Text(ClockText.offset(zone, at: clock.now)).font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
                    }
                }
            }
            if choosingZone {
                PanelSection(title: tr("clock.timeZone", "Time zone")) {
                    TextField(tr("clock.searchZone", "Search a city or region"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            zoneRow(nil)
                            ForEach(matchingZones, id: \.self) { identifier in zoneRow(identifier) }
                        }
                    }
                }
            } else {
                if !options.isOtherTimeZone {
                    MonthGrid(date: clock.now, theme: theme)
                }
                Divider().opacity(0.4)
                Toggle(tr("clock.analog", "Analog face"), isOn: Binding(get: { options.analogClock == true }, set: { value in
                    var next = options
                    next.analogClock = value
                    update(next)
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                Button(tr("clock.changeZone", "Change Time Zone…")) { choosingZone = true }
                    .buttonStyle(.link)
                    .font(PulseTypography.panelCaption)
            }
        }
        .onAppear { clock.showsSeconds = true }
        .onDisappear { clock.showsSeconds = false }
    }

    private func fullDate(_ zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()
        style.timeZone = zone
        return clock.now.formatted(style)
    }

    private var matchingZones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
        let needle = query.trimmingCharacters(in: .whitespaces).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !needle.isEmpty else { return Array(all.prefix(40)) }
        return all.filter {
            $0.replacingOccurrences(of: "_", with: " ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(needle)
        }
    }

    private func zoneRow(_ identifier: String?) -> some View {
        let selected = identifier == nil ? !options.isOtherTimeZone : options.timeZoneID == identifier
        return Button {
            var next = options
            next.timeZoneID = identifier
            update(next)
            query = ""
            choosingZone = false
        } label: {
            HStack {
                Text(identifier.map { ClockText.city(TimeZone(identifier: $0) ?? .current) + " · " + ($0.split(separator: "/").first.map(String.init) ?? "") }
                     ?? tr("clock.localZone", "This Mac's time zone"))
                    .font(PulseTypography.panelBody)
                Spacer()
                if let identifier, let zone = TimeZone(identifier: identifier) {
                    Text(ClockText.time(clock.now, in: zone)).font(PulseTypography.panelCaption).monospacedDigit().foregroundStyle(.secondary)
                }
                if selected { Image(systemName: "checkmark").foregroundStyle(theme.tone(.working)) }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar

struct CalendarTile: View {
    let events: EventKitProvider
    let clock: ClockProvider
    let theme: Theme

    var body: some View {
        let now = clock.now
        VStack(spacing: 0) {
            Text(now.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 9.5, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(theme.tone(.failure))
            Text(now.formatted(.dateTime.day()))
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.labelText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let next = events.nextEvent, next.start.timeIntervalSince(now) < 15 * 60 {
                Capsule().fill(theme.tone(.attention)).frame(width: 14, height: 3).offset(y: -1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.calendar", "Calendar"))
        .accessibilityValue(now.formatted(date: .complete, time: .omitted))
    }
}

struct CalendarPanel: View {
    let events: EventKitProvider
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: events.now.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
            switch events.calendarAccess {
            case .granted:
                if let next = events.nextEvent { nextEventCard(next) }
                agenda
            case .unknown:
                AccessPrompt(text: tr("calendar.access.prompt", "PulseDock shows your next events and a button to join video calls. Events are read on this Mac and never leave it."),
                             button: tr("calendar.access.allow", "Allow Calendar Access…"), theme: theme) { events.requestCalendarAccess() }
            case .denied:
                AccessPrompt(text: tr("calendar.access.denied", "Calendar access is off. Turn it on in System Settings › Privacy & Security › Calendars."),
                             button: tr("common.openSystemSettings", "Open System Settings"), theme: theme) {
                    SystemSettingsLink.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                }
            }
        }
    }

    private func nextEventCard(_ event: CalendarEventSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.calendarColor ?? .systemBlue)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(PulseTypography.panelHeadline).lineLimit(2)
                Text(when(event)).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty, !event.hasVideoCall {
                    Text(location).font(PulseTypography.panelCaption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let url = event.videoCallURL {
                PillButton(title: tr("calendar.join", "Join"), symbol: "video.fill", prominent: true, tint: theme.tone(.success)) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private var agenda: some View {
        let grouped = Dictionary(grouping: events.events) { Calendar.current.startOfDay(for: max($0.start, events.now)) }
        let days = grouped.keys.sorted().prefix(4)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if days.isEmpty {
                    Text(tr("calendar.empty", "Nothing on your calendar this week."))
                        .font(PulseTypography.panelBody).foregroundStyle(.secondary)
                }
                ForEach(Array(days), id: \.self) { day in
                    PanelSection(title: dayTitle(day)) {
                        ForEach(grouped[day] ?? []) { event in
                            HStack(spacing: 8) {
                                Circle().fill(Color(nsColor: event.calendarColor ?? .systemBlue)).frame(width: 7, height: 7)
                                Text(event.isAllDay ? tr("calendar.allDay", "All day") : event.start.formatted(date: .omitted, time: .shortened))
                                    .font(PulseTypography.panelCaption).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 58, alignment: .leading)
                                Text(event.title).font(PulseTypography.panelBody).lineLimit(1)
                                Spacer(minLength: 0)
                                if event.hasVideoCall { Image(systemName: "video").font(.system(size: 10)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return tr("calendar.today", "Today") }
        if Calendar.current.isDateInTomorrow(day) { return tr("calendar.tomorrow", "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).day())
    }

    private func when(_ event: CalendarEventSummary) -> String {
        if event.isAllDay { return tr("calendar.allDay", "All day") }
        if event.start <= events.now {
            return tr("calendar.endsIn", "Now · ends %@", event.end.formatted(date: .omitted, time: .shortened))
        }
        let minutes = Int(event.start.timeIntervalSince(events.now) / 60)
        if minutes < 60 { return trp("calendar.inMinutes", one: "In %ld minute", other: "In %ld minutes", max(1, minutes)) }
        return event.start.formatted(date: Calendar.current.isDateInToday(event.start) ? .omitted : .abbreviated, time: .shortened)
    }
}

/// Explains why a permission is useful before macOS asks for it.
struct AccessPrompt: View {
    let text: String
    let button: String
    let theme: Theme
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(PulseTypography.panelBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PillButton(title: button, prominent: true, tint: theme.tone(.working), action: action)
        }
    }
}

enum SystemSettingsLink {
    static func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Timer

struct TimerTile: View {
    let timers: FocusTimersProvider
    let theme: Theme

    var body: some View {
        let timer = timers.timer
        let running = timer.isRunning || timer.remaining(at: timers.now) < timer.duration
        Group {
            if running {
                WidgetRing(progress: 1 - timer.progress(at: timers.now), color: theme.tone(timer.isRunning ? .working : .idle)) {
                    Text(TimeMath.clock(timer.remaining(at: timers.now)))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                }
                .padding(4)
            } else {
                SymbolTile(symbol: "timer", theme: theme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.timer", "Timer"))
        .accessibilityValue(running ? TimeMath.clock(timer.remaining(at: timers.now)) : tr("timer.idle", "Not running"))
    }
}

struct TimerPanel: View {
    let timers: FocusTimersProvider
    let data: WidgetDataStore
    let theme: Theme
    let accessibility: AccessibilityOptions
    private let presets: [Double] = [1, 3, 5, 10, 15, 25, 45, 60]

    var body: some View {
        let timer = timers.timer
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.timer", "Timer")) {
            HStack(spacing: 16) {
                WidgetRing(progress: 1 - timer.progress(at: timers.now), color: theme.tone(.working), lineWidth: 6) {
                    Text(TimeMath.clock(timer.remaining(at: timers.now)))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 8) {
                    PillButton(title: timer.isRunning ? tr("timer.pause", "Pause") : tr("timer.start", "Start"),
                               symbol: timer.isRunning ? "pause.fill" : "play.fill", prominent: true, tint: theme.tone(.working)) { timers.toggleTimer() }
                    PillButton(title: tr("timer.reset", "Reset"), symbol: "arrow.counterclockwise", tint: theme.tone(.idle)) { timers.resetTimer() }
                    Stepper(value: Binding(get: { data.data.timerMinutes }, set: { value in
                        data.update { $0.timerMinutes = value }
                        timers.timer.reset(duration: value * 60)
                    }), in: 1...240, step: 1) {
                        Text(trp("timer.minutes", one: "%ld minute", other: "%ld minutes", Int(data.data.timerMinutes)))
                            .font(PulseTypography.panelCaption)
                    }
                    .controlSize(.small)
                }
            }
            PanelSection(title: tr("timer.presets", "Quick start")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(presets, id: \.self) { minutes in
                        PillButton(title: tr("timer.presetMinutes", "%ld min", Int(minutes)), tint: theme.tone(.working)) {
                            data.update { $0.timerMinutes = minutes }
                            timers.setTimer(minutes: minutes)
                        }
                    }
                }
            }
            Text(tr("timer.footer", "A sound and a notification tell you when it ends."))
                .font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Stopwatch

struct StopwatchTile: View {
    let timers: FocusTimersProvider
    let theme: Theme

    var body: some View {
        let elapsed = timers.stopwatch.elapsed(at: timers.now)
        Group {
            if elapsed > 0 {
                VStack(spacing: 1) {
                    Image(systemName: "stopwatch").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.tone(timers.stopwatch.isRunning ? .working : .idle))
                    Text(TimeMath.clock(elapsed))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                }
            } else {
                SymbolTile(symbol: "stopwatch", theme: theme)
            }
        }
        .foregroundStyle(theme.labelText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.stopwatch", "Stopwatch"))
        .accessibilityValue(TimeMath.clock(elapsed))
    }
}

struct StopwatchPanel: View {
    let timers: FocusTimersProvider
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        let watch = timers.stopwatch
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.stopwatch", "Stopwatch")) {
            Text(TimeMath.clock(watch.elapsed(at: timers.now), tenths: true))
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                PillButton(title: watch.isRunning ? tr("timer.pause", "Pause") : tr("timer.start", "Start"),
                           symbol: watch.isRunning ? "pause.fill" : "play.fill", prominent: true, tint: theme.tone(.working)) { timers.toggleStopwatch() }
                PillButton(title: tr("stopwatch.lap", "Lap"), symbol: "flag", tint: theme.tone(.idle)) { timers.lap() }
                    .disabled(!watch.isRunning)
                PillButton(title: tr("timer.reset", "Reset"), symbol: "arrow.counterclockwise", tint: theme.tone(.idle)) { timers.resetStopwatch() }
            }
            .frame(maxWidth: .infinity)
            if !watch.laps.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(watch.lapDurations.enumerated()), id: \.offset) { index, lap in
                            HStack {
                                Text(tr("stopwatch.lapNumber", "Lap %ld", watch.laps.count - index)).font(PulseTypography.panelBody)
                                Spacer()
                                Text(TimeMath.clock(lap, tenths: true)).font(PulseTypography.mono).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .onAppear { timers.highFrequency = true }
        .onDisappear { timers.highFrequency = false }
    }
}

// MARK: - Pomodoro

extension PomodoroCycle.Phase {
    var displayName: String {
        switch self {
        case .focus: tr("pomodoro.focus", "Focus")
        case .shortBreak: tr("pomodoro.shortBreak", "Short break")
        case .longBreak: tr("pomodoro.longBreak", "Long break")
        }
    }

    var tone: StatusTone { self == .focus ? .failure : .success }
}

struct PomodoroTile: View {
    let timers: FocusTimersProvider
    let theme: Theme

    var body: some View {
        let cycle = timers.pomodoro
        let started = cycle.timer.isRunning || cycle.timer.remaining(at: timers.now) < cycle.timer.duration
        WidgetRing(progress: started ? cycle.timer.progress(at: timers.now) : Double(timers.focusToday) / Double(max(1, cycle.configuration.dailyGoal)),
                   color: theme.tone(cycle.phase.tone)) {
            if started {
                Text(TimeMath.clock(cycle.timer.remaining(at: timers.now)))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.tone(.failure))
                    Text("\(timers.focusToday)/\(cycle.configuration.dailyGoal)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.pomodoro", "Pomodoro"))
        .accessibilityValue(started ? "\(cycle.phase.displayName), \(TimeMath.clock(cycle.timer.remaining(at: timers.now)))"
                            : trp("pomodoro.doneToday", one: "%ld focus session today", other: "%ld focus sessions today", timers.focusToday))
    }
}

struct PomodoroPanel: View {
    let timers: FocusTimersProvider
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        let cycle = timers.pomodoro
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.pomodoro", "Pomodoro")) {
            HStack(spacing: 16) {
                WidgetRing(progress: cycle.timer.progress(at: timers.now), color: theme.tone(cycle.phase.tone), lineWidth: 6) {
                    VStack(spacing: 0) {
                        Text(TimeMath.clock(cycle.timer.remaining(at: timers.now)))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(cycle.phase.displayName).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 8) {
                    PillButton(title: cycle.timer.isRunning ? tr("timer.pause", "Pause") : tr("timer.start", "Start"),
                               symbol: cycle.timer.isRunning ? "pause.fill" : "play.fill", prominent: true, tint: theme.tone(cycle.phase.tone)) { timers.togglePomodoro() }
                    PillButton(title: tr("pomodoro.skip", "Skip"), symbol: "forward.end", tint: theme.tone(.idle)) { timers.skipPomodoroPhase() }
                    PillButton(title: tr("timer.reset", "Reset"), symbol: "arrow.counterclockwise", tint: theme.tone(.idle)) { timers.resetPomodoro() }
                }
            }
            HStack(spacing: 5) {
                ForEach(0..<cycle.configuration.focusesBeforeLongBreak, id: \.self) { index in
                    Circle()
                        .fill(index < cycle.focusesInSet ? theme.tone(.failure) : Color.primary.opacity(0.14))
                        .frame(width: 8, height: 8)
                }
                Text(tr("pomodoro.untilLongBreak", "until the long break")).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tr("pomodoro.today", "Today")).font(PulseTypography.panelBody)
                    Spacer()
                    Text("\(timers.focusToday) / \(cycle.configuration.dailyGoal)").font(PulseTypography.panelBody).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, Double(timers.focusToday) / Double(max(1, cycle.configuration.dailyGoal)))).tint(theme.tone(.failure))
            }
            Text(tr("pomodoro.footer", "25 minutes of focus, 5 of rest, and a longer break after four. The next phase starts on its own."))
                .font(PulseTypography.panelCaption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Countdown

struct CountdownTile: View {
    let options: WidgetOptions
    let clock: ClockProvider
    let theme: Theme

    var body: some View {
        Group {
            if let target = options.countdownDate {
                let days = TimeMath.daysUntil(target, from: clock.now)
                VStack(spacing: 1) {
                    Text(Int(abs(days)), format: .number)
                        .font(.system(size: days.magnitude > 999 ? 14 : 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(days == 0 ? theme.tone(.success) : theme.labelText)
                    Image(systemName: days == 0 ? "party.popper" : (days > 0 ? "hourglass" : "clock.arrow.circlepath"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                SymbolTile(symbol: "hourglass", theme: theme, caption: tr("countdown.set", "Set date"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(options.countdownTitle ?? tr("widget.countdown", "Countdown"))
        .accessibilityValue(options.countdownDate.map { trp("countdown.accessibility", one: "%ld day left", other: "%ld days left", TimeMath.daysUntil($0, from: clock.now)) } ?? "")
    }
}

struct CountdownPanel: View {
    let options: WidgetOptions
    let clock: ClockProvider
    let theme: Theme
    let accessibility: AccessibilityOptions
    let update: (WidgetOptions) -> Void

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: options.countdownTitle?.isEmpty == false ? options.countdownTitle! : tr("widget.countdown", "Countdown")) {
            if let target = options.countdownDate {
                let days = TimeMath.daysUntil(target, from: clock.now)
                Text(days == 0 ? tr("countdown.isToday", "It's today!")
                     : (days > 0 ? trp("countdown.daysUntil", one: "%ld day to go", other: "%ld days to go", abs(days))
                                 : trp("countdown.daysSince", one: "%ld day ago", other: "%ld days ago", abs(days))))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(target.formatted(date: .complete, time: .omitted)).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
            }
            TextField(tr("countdown.titlePlaceholder", "What are you counting down to?"), text: Binding(get: { options.countdownTitle ?? "" }, set: { value in
                var next = options
                next.countdownTitle = String(value.prefix(60))
                update(next)
            }))
            .textFieldStyle(.roundedBorder)
            DatePicker(tr("countdown.date", "Date"), selection: Binding(get: { options.countdownDate ?? Calendar.current.date(byAdding: .day, value: 30, to: clock.now) ?? clock.now }, set: { value in
                var next = options
                next.countdownDate = value
                update(next)
            }), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
        }
    }
}

// MARK: - Time Progress

extension TimeProgressScope {
    var displayName: String {
        switch self {
        case .day: tr("timeProgress.day", "Day")
        case .week: tr("timeProgress.week", "Week")
        case .month: tr("timeProgress.month", "Month")
        case .year: tr("timeProgress.year", "Year")
        }
    }
}

struct TimeProgressTile: View {
    let options: WidgetOptions
    let clock: ClockProvider
    let theme: Theme

    var body: some View {
        let scope = options.progressScope ?? .year
        let value = TimeMath.progress(scope, at: clock.now)
        WidgetRing(progress: value, color: theme.tone(.working)) {
            VStack(spacing: -1) {
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(scope.displayName)
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.timeProgress", "Time Progress"))
        .accessibilityValue("\(scope.displayName): \(value.formatted(.percent.precision(.fractionLength(0))))")
    }
}

struct TimeProgressPanel: View {
    let options: WidgetOptions
    let clock: ClockProvider
    let theme: Theme
    let accessibility: AccessibilityOptions
    let update: (WidgetOptions) -> Void

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.timeProgress", "Time Progress")) {
            ForEach(TimeProgressScope.allCases, id: \.self) { scope in
                let value = TimeMath.progress(scope, at: clock.now)
                Button {
                    var next = options
                    next.progressScope = scope
                    update(next)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(scope.displayName).font(PulseTypography.panelBody)
                            if (options.progressScope ?? .year) == scope {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(theme.tone(.working))
                            }
                            Spacer()
                            Text(value, format: .percent.precision(.fractionLength(1))).font(PulseTypography.panelBody).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: value).tint(theme.tone(.working))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(tr("timeProgress.footer", "Click a row to show it on the tile."))
                .font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
        }
    }
}
