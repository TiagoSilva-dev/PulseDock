import AppKit
import DockCore
import DockRendering
import SwiftUI
import WidgetCore

// MARK: - Reminders

struct RemindersTile: View {
    let events: EventKitProvider
    let theme: Theme

    var body: some View {
        let due = events.reminders.filter { reminder in
            guard let date = reminder.due else { return false }
            return date < Calendar.current.startOfDay(for: events.now).addingTimeInterval(86_400)
        }.count
        SymbolTile(symbol: "checklist", theme: theme, tint: theme.tone(due > 0 ? .attention : .idle), badge: due)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("widget.reminders", "Reminders"))
            .accessibilityValue(trp("reminders.dueCount", one: "%ld due today", other: "%ld due today", due))
    }
}

struct RemindersPanel: View {
    let events: EventKitProvider
    let theme: Theme
    let accessibility: AccessibilityOptions
    @State private var draft = ""

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.reminders", "Reminders")) {
            switch events.remindersAccess {
            case .granted:
                HStack(spacing: 6) {
                    TextField(tr("reminders.new", "New reminder"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(action: add) { Image(systemName: "plus.circle.fill").font(.system(size: 18)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.tone(.working))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel(tr("reminders.add", "Add reminder"))
                }
                if events.reminders.isEmpty {
                    Text(tr("reminders.empty", "All done. Nothing pending."))
                        .font(PulseTypography.panelBody).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(events.reminders) { reminder in row(reminder) }
                    }
                }
            case .unknown:
                AccessPrompt(text: tr("reminders.access.prompt", "PulseDock shows what is due next and lets you tick reminders off from the dock. They stay on this Mac."),
                             button: tr("reminders.access.allow", "Allow Reminders Access…"), theme: theme) { events.requestRemindersAccess() }
            case .denied:
                AccessPrompt(text: tr("reminders.access.denied", "Reminders access is off. Turn it on in System Settings › Privacy & Security › Reminders."),
                             button: tr("common.openSystemSettings", "Open System Settings"), theme: theme) {
                    SystemSettingsLink.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
                }
            }
        }
    }

    private func add() {
        events.addReminder(draft)
        draft = ""
    }

    private func row(_ reminder: ReminderSummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.2)) { events.complete(reminder) } } label: {
                Image(systemName: "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(nsColor: reminder.listColor ?? .systemOrange))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("reminders.complete", "Mark as completed"))
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title).font(PulseTypography.panelBody).lineLimit(2)
                if let due = reminder.due {
                    Text(due.formatted(date: Calendar.current.isDateInToday(due) ? .omitted : .abbreviated, time: .shortened))
                        .font(PulseTypography.panelCaption)
                        .foregroundStyle(due < events.now ? theme.tone(.failure) : .secondary)
                }
            }
            Spacer(minLength: 0)
            if reminder.priority > 0 && reminder.priority <= 4 {
                Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.tone(.attention))
            }
        }
    }
}

// MARK: - Note

struct NoteTile: View {
    let text: String
    let theme: Theme

    var body: some View {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)
        HStack(spacing: 6) {
            Image(systemName: "note.text").font(.system(size: 14, weight: .medium)).foregroundStyle(theme.tone(.attention))
            Text(firstLine?.isEmpty == false ? firstLine! : tr("note.placeholder", "Write a note…"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(firstLine == nil ? .secondary : theme.labelText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.note", "Note"))
        .accessibilityValue(text)
    }
}

struct NotePanel: View {
    let placementID: UUID
    let data: WidgetDataStore
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        let key = placementID.uuidString
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.note", "Note")) {
            TextEditor(text: Binding(get: { data.data.notes[key] ?? "" }, set: { value in
                data.update { $0.notes[key] = String(value.prefix(20_000)) }
            }))
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            HStack {
                Text(tr("note.footer", "Saved automatically on this Mac. Drop text on the tile to append it."))
                    .font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
                Spacer()
                Button(tr("note.copy", "Copy")) { Pasteboard.copy(data.data.notes[key] ?? "") }
                    .buttonStyle(.link).font(PulseTypography.panelCaption)
            }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsTile: View {
    let runner: ShortcutsRunner
    let theme: Theme

    var body: some View {
        let icon = NSWorkspaceLookup.url(forBundleIdentifier: "com.apple.shortcuts").map { IconProvider.shared.icon(forPath: $0.path) }
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).padding(3)
            } else {
                SymbolTile(symbol: "square.2.layers.3d", theme: theme)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !runner.running.isEmpty {
                ProgressView().controlSize(.mini).padding(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(tr("widget.shortcuts", "Shortcuts"))
    }
}

struct ShortcutsPanel: View {
    let runner: ShortcutsRunner
    let theme: Theme
    let accessibility: AccessibilityOptions
    @State private var query = ""

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.shortcuts", "Shortcuts")) {
            if !runner.isAvailable {
                Text(tr("shortcuts.unavailable", "The Shortcuts command-line tool is not available on this Mac."))
                    .font(PulseTypography.panelBody).foregroundStyle(.secondary)
            } else {
                TextField(tr("shortcuts.search", "Search shortcuts"), text: $query).textFieldStyle(.roundedBorder)
                let matches = runner.shortcuts.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                if runner.shortcuts.isEmpty {
                    Text(tr("shortcuts.empty", "No shortcuts yet. Create one in the Shortcuts app."))
                        .font(PulseTypography.panelBody).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(matches, id: \.self) { name in
                            Button { runner.run(name) } label: {
                                HStack {
                                    Image(systemName: "play.circle.fill").foregroundStyle(theme.tone(.working))
                                    Text(name).font(PulseTypography.panelBody).lineLimit(1)
                                    Spacer()
                                    if runner.running.contains(name) { ProgressView().controlSize(.small) }
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let result = runner.lastResult {
                    Label(result.succeeded ? tr("shortcuts.ran", "“%@” finished", result.name) : tr("shortcuts.failed", "“%@” did not finish", result.name),
                          systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(PulseTypography.panelCaption)
                        .foregroundStyle(theme.tone(result.succeeded ? .success : .failure))
                }
            }
        }
        .onAppear { runner.reload() }
    }
}

// MARK: - Water

struct WaterTile: View {
    let data: WidgetDataStore
    let options: WidgetOptions
    let clock: ClockProvider
    let theme: Theme

    var body: some View {
        let goal = max(1, options.waterGoal ?? 8)
        let today = data.data.water[TimeMath.dayKey(clock.now)] ?? 0
        WidgetRing(progress: Double(today) / Double(goal), color: Color(nsColor: .systemTeal)) {
            VStack(spacing: -2) {
                Image(systemName: "drop.fill").font(.system(size: 10)).foregroundStyle(Color(nsColor: .systemTeal))
                Text("\(today)").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.water", "Water"))
        .accessibilityValue(tr("water.accessibilityValue", "Glasses: %ld of %ld", today, goal))
    }
}

struct WaterPanel: View {
    let data: WidgetDataStore
    let options: WidgetOptions
    let clock: ClockProvider
    let theme: Theme
    let accessibility: AccessibilityOptions
    let update: (WidgetOptions) -> Void

    var body: some View {
        let goal = max(1, options.waterGoal ?? 8)
        let key = TimeMath.dayKey(clock.now)
        let today = data.data.water[key] ?? 0
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.water", "Water")) {
            HStack(spacing: 16) {
                WidgetRing(progress: Double(today) / Double(goal), color: Color(nsColor: .systemTeal), lineWidth: 6) {
                    VStack(spacing: 0) {
                        Text("\(today)").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(tr("water.ofGoal", "of %ld", goal)).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 100, height: 100)
                VStack(alignment: .leading, spacing: 8) {
                    PillButton(title: tr("water.add", "Add a glass"), symbol: "plus", prominent: true, tint: Color(nsColor: .systemTeal)) {
                        data.update { $0.water[key, default: 0] += 1 }
                    }
                    PillButton(title: tr("water.remove", "Undo"), symbol: "minus", tint: theme.tone(.idle)) {
                        data.update { $0.water[key] = max(0, ($0.water[key] ?? 0) - 1) }
                    }
                    .disabled(today == 0)
                    Stepper(value: Binding(get: { goal }, set: { value in
                        var next = options
                        next.waterGoal = value
                        update(next)
                    }), in: 1...20) {
                        Text(tr("water.goal", "Goal: %ld", goal)).font(PulseTypography.panelCaption)
                    }
                    .controlSize(.small)
                }
            }
            PanelSection(title: tr("water.week", "Last 7 days")) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<7, id: \.self) { offset in
                        let day = Calendar.current.date(byAdding: .day, value: offset - 6, to: clock.now) ?? clock.now
                        let count = data.data.water[TimeMath.dayKey(day)] ?? 0
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(count >= goal ? Color(nsColor: .systemTeal) : Color(nsColor: .systemTeal).opacity(0.4))
                                .frame(width: 18, height: max(3, 46 * min(1, Double(count) / Double(goal))))
                            Text(day.formatted(.dateTime.weekday(.narrow))).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}
