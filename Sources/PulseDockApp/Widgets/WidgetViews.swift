import Diagnostics
import DockCore
import DockRendering
import SwiftUI
import WidgetCore

// MARK: - Compact tiles (inside the dock)

struct SystemHealthTile: View {
    let health: SystemHealthProvider
    let theme: Theme

    var body: some View {
        HStack(spacing: 7) {
            meter(value: health.cpuUsage, label: "CPU", tone: health.cpuUsage > 0.85 ? .attention : .working)
            meter(value: health.memoryFraction, label: "MEM", tone: health.memoryFraction > 0.9 ? .attention : .success)
            if let battery = health.battery {
                meter(value: battery.level, label: battery.isCharging ? "⚡︎" : "BAT", tone: battery.level < 0.15 && !battery.isPluggedIn ? .failure : .idle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.systemHealth", "System Health"))
        .accessibilityValue(tr("widget.systemHealth.value", "CPU %ld percent, memory %ld percent", Int(health.cpuUsage * 100), Int(health.memoryFraction * 100)))
    }

    private func meter(value: Double, label: String, tone: StatusTone) -> some View {
        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(theme.tone(tone))
                    .frame(height: max(3, 26 * min(1, max(0, value))))
            }
            .frame(width: 6, height: 26)
            Text(label)
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct NowPlayingTile: View {
    let player: NowPlayingProvider
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [theme.tone(.working).opacity(0.75), theme.accentGradient.last ?? .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: player.track?.isPlaying == true ? "waveform" : "music.note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.track?.title ?? tr("widget.nowPlaying.idle", "Nothing playing"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(player.track?.artist ?? tr("widget.nowPlaying.hint", "Music · Spotify"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.labelText)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Expanded panels

struct WidgetPanelContainer<Content: View>: View {
    let theme: Theme
    let accessibility: AccessibilityOptions
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(PulseTypography.panelTitle)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            PulseGlassSurface(theme: theme, cornerRadius: PanelMetrics.cornerRadius, accessibility: accessibility, legibility: .content)
        }
        .environment(\.colorScheme, theme.forcedColorScheme ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
    }
}

struct MonthGrid: View {
    let date: Date
    let theme: Theme

    var body: some View {
        let calendar = Calendar.current
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<31
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let today = calendar.component(.day, from: date)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        let columns = Array(repeating: GridItem(.fixed(28), spacing: 2), count: 7)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 20) }
            ForEach(Array(range), id: \.self) { day in
                Text("\(day)")
                    .font(.system(size: 11.5, weight: day == today ? .bold : .regular))
                    .monospacedDigit()
                    .frame(width: 24, height: 20)
                    .background(Circle().fill(day == today ? theme.tone(.working) : .clear).frame(width: 22, height: 22))
                    .foregroundStyle(day == today ? Color.white : Color.primary)
            }
        }
    }
}

struct SystemHealthPanel: View {
    let health: SystemHealthProvider
    let theme: Theme
    let accessibility: AccessibilityOptions
    @State private var ownMemory: UInt64 = ProcessMetrics.physicalFootprint() ?? 0

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.systemHealth", "System Health")) {
            row(title: tr("widget.health.cpu", "Processor"), value: String(format: "%.0f%%", health.cpuUsage * 100), fraction: health.cpuUsage, tone: .working)
            Sparkline(values: health.cpuHistory, color: theme.tone(.working)).frame(height: 28)
            row(title: tr("widget.health.memory", "Memory"),
                value: "\(ProcessMetrics.formattedBytes(health.memoryUsed)) / \(ProcessMetrics.formattedBytes(health.memoryTotal))",
                fraction: health.memoryFraction, tone: .success)
            if let battery = health.battery {
                row(title: battery.isCharging ? tr("widget.health.batteryCharging", "Battery · charging") : tr("widget.health.battery", "Battery"),
                    value: batteryText(battery), fraction: battery.level, tone: battery.level < 0.15 ? .failure : .idle)
            }
            Divider().opacity(0.4)
            Text(tr("widget.health.pulsedock", "PulseDock itself uses %@ of memory.", ProcessMetrics.formattedBytes(ownMemory)))
                .font(PulseTypography.panelCaption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            health.interval = 2
            ownMemory = ProcessMetrics.physicalFootprint() ?? 0
        }
        .onDisappear { health.interval = 5 }
    }

    private func batteryText(_ battery: SystemHealthProvider.Battery) -> String {
        var text = String(format: "%.0f%%", battery.level * 100)
        if let minutes = battery.minutesRemaining, minutes > 0 {
            text += " · " + Formatting.duration(Double(minutes) * 60)
        }
        return text
    }

    private func row(title: String, value: String, fraction: Double, tone: StatusTone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(PulseTypography.panelBody)
                Spacer()
                Text(value).font(PulseTypography.panelBody).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, max(0, fraction))).tint(theme.tone(tone))
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                let step = proxy.size.width / Double(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: Double(index) * step, y: proxy.size.height * (1 - min(1, max(0, value))))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct NowPlayingPanel: View {
    let player: NowPlayingProvider
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.nowPlaying", "Now Playing")) {
            if let track = player.track {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    if let artist = track.artist { Text(artist).font(PulseTypography.panelBody).foregroundStyle(.secondary) }
                    if let album = track.album { Text(album).font(PulseTypography.panelCaption).foregroundStyle(.tertiary) }
                    Text(track.player == .music ? "Music" : "Spotify").font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
                }
            } else {
                Text(player.runningPlayers.isEmpty
                     ? tr("widget.nowPlaying.noPlayer", "Open Music or Spotify to see what is playing.")
                     : tr("widget.nowPlaying.waiting", "Track details appear when playback changes."))
                    .font(PulseTypography.panelBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 22) {
                control("backward.fill", .previous)
                control(player.track?.isPlaying == true ? "pause.fill" : "play.fill", .playPause).font(.system(size: 22))
                control("forward.fill", .next)
            }
            .frame(maxWidth: .infinity)
            .disabled(player.runningPlayers.isEmpty)
            if let error = player.lastControlError {
                Text(error.contains("-1743")
                     ? tr("widget.nowPlaying.permission", "Allow PulseDock to control the player in System Settings › Privacy & Security › Automation.")
                     : error)
                    .font(PulseTypography.panelCaption)
                    .foregroundStyle(theme.tone(.attention))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(tr("widget.nowPlaying.consent", "Controls use Apple Events; macOS asks once for permission."))
                    .font(PulseTypography.panelCaption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func control(_ symbol: String, _ command: NowPlayingProvider.Command) -> some View {
        Button { player.send(command) } label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .font(.system(size: 16))
    }
}

struct QuickLaunchPanel: View {
    let collection: QuickLaunchCollection?
    let theme: Theme
    let accessibility: AccessibilityOptions
    let open: (PinnedItem) -> Void
    let edit: () -> Void

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: collection?.name ?? tr("widget.quickLaunch", "Quick Launch")) {
            let items = collection?.items ?? []
            if items.isEmpty {
                Text(tr("widget.quickLaunch.empty", "This collection is empty. Add apps, folders or files in Settings › Appearance."))
                    .font(PulseTypography.panelBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 8), count: 4), spacing: 12) {
                    ForEach(items) { item in
                        Button { open(item) } label: {
                            VStack(spacing: 4) {
                                Image(nsImage: IconProvider.shared.icon(forPath: NSWorkspaceLookup.resolve(item)?.path ?? item.path))
                                    .resizable()
                                    .frame(width: 44, height: 44)
                                Text(NSWorkspaceLookup.resolve(item).map(NSWorkspaceLookup.displayName(for:)) ?? (item.path as NSString).lastPathComponent)
                                    .font(.system(size: 10.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(width: 72)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button(tr("widget.quickLaunch.edit", "Edit Collections…"), action: edit)
                .buttonStyle(.link)
                .font(PulseTypography.panelCaption)
        }
    }
}
