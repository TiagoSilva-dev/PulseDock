import AppKit
import DockRendering
import SwiftUI
import WidgetCore

// MARK: - Network

struct NetworkTile: View {
    let network: NetworkRateProvider
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            rate("arrow.down", network.downloadRate, theme.tone(.working))
            rate("arrow.up", network.uploadRate, theme.tone(.success))
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.network", "Network"))
        .accessibilityValue(tr("network.accessibility", "Download %@, upload %@", NetworkRateProvider.format(network.downloadRate), NetworkRateProvider.format(network.uploadRate)))
    }

    private func rate(_ symbol: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(color)
            Text(NetworkRateProvider.format(value))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(theme.labelText)
        }
    }
}

struct NetworkPanel: View {
    let network: NetworkRateProvider
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        let peak = max(1, (network.downloadHistory + network.uploadHistory).max() ?? 1)
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.network", "Network")) {
            row(tr("network.download", "Download"), network.downloadRate, color: theme.tone(.working))
            Sparkline(values: network.downloadHistory.map { $0 / peak }, color: theme.tone(.working)).frame(height: 30)
            row(tr("network.upload", "Upload"), network.uploadRate, color: theme.tone(.success))
            Sparkline(values: network.uploadHistory.map { $0 / peak }, color: theme.tone(.success)).frame(height: 30)
            Text(tr("network.footer", "Wi-Fi and Ethernet together, sampled every second while this panel is open."))
                .font(PulseTypography.panelCaption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { network.interval = 1 }
        .onDisappear { network.interval = 2 }
    }

    private func row(_ title: String, _ value: Double, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(PulseTypography.panelBody)
            Spacer()
            Text(NetworkRateProvider.format(value)).font(PulseTypography.panelBody).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

// MARK: - Battery

struct BatteryTile: View {
    let health: SystemHealthProvider
    let theme: Theme

    var body: some View {
        Group {
            if let battery = health.battery {
                WidgetRing(progress: battery.level, color: theme.tone(battery.level < 0.15 && !battery.isPluggedIn ? .failure : (battery.isCharging ? .success : .idle))) {
                    VStack(spacing: -1) {
                        if battery.isCharging || battery.isPluggedIn {
                            Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(theme.tone(.success))
                        }
                        Text("\(Int((battery.level * 100).rounded()))")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .padding(4)
            } else {
                SymbolTile(symbol: "powerplug", theme: theme, caption: tr("battery.ac", "Power"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("widget.battery", "Battery"))
        .accessibilityValue(health.battery.map { "\(Int(($0.level * 100).rounded()))%" } ?? tr("battery.none", "No battery"))
    }
}

struct BatteryPanel: View {
    let health: SystemHealthProvider
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.battery", "Battery")) {
            if let battery = health.battery {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int((battery.level * 100).rounded()))%").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    if battery.isCharging { Image(systemName: "bolt.fill").foregroundStyle(theme.tone(.success)) }
                }
                ProgressView(value: battery.level).tint(theme.tone(battery.level < 0.15 ? .failure : .success))
                Text(status(battery)).font(PulseTypography.panelBody).foregroundStyle(.secondary)
                Button(tr("battery.settings", "Battery Settings…")) {
                    SystemSettingsLink.open("x-apple.systempreferences:com.apple.Battery-Settings.extension")
                }
                .buttonStyle(.link)
                .font(PulseTypography.panelCaption)
            } else {
                Text(tr("battery.noneBody", "This Mac runs on power and has no battery."))
                    .font(PulseTypography.panelBody).foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ battery: SystemHealthProvider.Battery) -> String {
        let minutes = battery.minutesRemaining ?? 0
        if battery.isCharging {
            return minutes > 0 ? tr("battery.untilFull", "Charging · full in %@", Formatting.duration(Double(minutes) * 60)) : tr("battery.charging", "Charging")
        }
        if battery.isPluggedIn { return tr("battery.pluggedIn", "Plugged in, not charging") }
        return minutes > 0 ? tr("battery.remaining", "%@ remaining", Formatting.duration(Double(minutes) * 60)) : tr("battery.estimating", "Estimating time remaining…")
    }
}

// MARK: - Weather

extension WeatherCondition {
    var displayName: String {
        switch self {
        case .clear: tr("weather.clear", "Clear")
        case .partlyCloudy: tr("weather.partlyCloudy", "Partly cloudy")
        case .cloudy: tr("weather.cloudy", "Cloudy")
        case .fog: tr("weather.fog", "Fog")
        case .drizzle: tr("weather.drizzle", "Drizzle")
        case .rain: tr("weather.rain", "Rain")
        case .freezingRain: tr("weather.freezingRain", "Freezing rain")
        case .snow: tr("weather.snow", "Snow")
        case .showers: tr("weather.showers", "Showers")
        case .thunderstorm: tr("weather.thunderstorm", "Thunderstorm")
        }
    }
}

enum WeatherText {
    static func temperature(_ value: Double) -> String { "\(Int(value.rounded()))°" }
}

struct WeatherTile: View {
    let weather: WeatherProvider
    let theme: Theme

    var body: some View {
        Group {
            if let report = weather.report {
                let condition = WeatherCondition(code: report.code)
                HStack(spacing: 5) {
                    Image(systemName: condition.symbol(isDay: report.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 19))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(WeatherText.temperature(report.temperature))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.labelText)
                        if let today = report.days.first {
                            Text("\(WeatherText.temperature(today.high)) \(WeatherText.temperature(today.low))")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                SymbolTile(symbol: "cloud.sun", theme: theme, caption: weather.place == nil ? tr("weather.setCity", "Set city") : nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(weather.place?.name ?? tr("widget.weather", "Weather"))
        .accessibilityValue(weather.report.map { "\(WeatherText.temperature($0.temperature)), \(WeatherCondition(code: $0.code).displayName)" } ?? "")
    }
}

struct WeatherPanel: View {
    let weather: WeatherProvider
    let options: WidgetOptions
    let theme: Theme
    let accessibility: AccessibilityOptions
    let update: (WidgetOptions) -> Void
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var searching = false
    @State private var editing = false

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: weather.place?.name ?? tr("widget.weather", "Weather")) {
            if weather.place == nil || editing {
                search
            } else if let report = weather.report {
                forecast(report)
            } else if weather.lastError != nil {
                Text(tr("weather.error", "The forecast could not be loaded. Check your connection."))
                    .font(PulseTypography.panelBody).foregroundStyle(.secondary)
                PillButton(title: tr("weather.retry", "Try Again"), tint: theme.tone(.working)) { weather.refresh(force: true) }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                if weather.place != nil {
                    Button(editing ? tr("common.cancel", "Cancel") : tr("weather.changeCity", "Change City…")) { editing.toggle() }
                    Picker("", selection: Binding(get: { options.fahrenheit == true }, set: { value in
                        var next = options
                        next.fahrenheit = value
                        update(next)
                    })) {
                        Text("°C").tag(false)
                        Text("°F").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                }
                Spacer()
                Link(tr("weather.attribution", "Weather data by Open-Meteo.com"), destination: URL(string: "https://open-meteo.com/")!)
            }
            .buttonStyle(.link)
            .font(PulseTypography.panelCaption)
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("weather.searchHint", "Type a city. Only its coordinates are sent to Open-Meteo; PulseDock never uses your location."))
                .font(PulseTypography.panelCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(tr("weather.city", "City"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runSearch)
                if searching { ProgressView().controlSize(.small) }
            }
            ForEach(results) { place in
                Button {
                    var next = options
                    next.weatherPlace = place
                    update(next)
                    editing = false
                    results = []
                    query = ""
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name).font(PulseTypography.panelBody)
                        if let region = place.region { Text(region).font(PulseTypography.panelCaption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func runSearch() {
        let text = query
        searching = true
        Task { @MainActor in
            results = await WeatherProvider.search(text)
            searching = false
        }
    }

    private func forecast(_ report: WeatherReport) -> some View {
        let condition = WeatherCondition(code: report.code)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: condition.symbol(isDay: report.isDay)).symbolRenderingMode(.multicolor).font(.system(size: 40))
                VStack(alignment: .leading, spacing: 2) {
                    Text(WeatherText.temperature(report.temperature)).font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text(condition.displayName).font(PulseTypography.panelBody).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(tr("weather.feelsLike", "Feels like %@", WeatherText.temperature(report.apparentTemperature)))
                    if let humidity = report.humidity { Text(tr("weather.humidity", "Humidity %ld%%", humidity)) }
                    if let wind = report.windSpeed { Text(tr("weather.wind", "Wind %ld km/h", Int(wind.rounded()))) }
                }
                .font(PulseTypography.panelCaption)
                .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(report.hours) { hour in
                        VStack(spacing: 4) {
                            Text(hour.date.formatted(.dateTime.hour())).font(.system(size: 10)).foregroundStyle(.secondary)
                            Image(systemName: WeatherCondition(code: hour.code).symbol()).symbolRenderingMode(.multicolor).font(.system(size: 14))
                            Text(WeatherText.temperature(hour.temperature)).font(.system(size: 11.5, weight: .medium))
                        }
                    }
                }
            }
            VStack(spacing: 6) {
                ForEach(report.days) { day in
                    HStack {
                        Text(Calendar.current.isDateInToday(day.date) ? tr("calendar.today", "Today") : day.date.formatted(.dateTime.weekday(.wide)))
                            .font(PulseTypography.panelBody)
                            .frame(width: 92, alignment: .leading)
                        Image(systemName: WeatherCondition(code: day.code).symbol()).symbolRenderingMode(.multicolor).frame(width: 22)
                        if let chance = day.precipitationChance, chance >= 20 {
                            Text("\(chance)%").font(PulseTypography.panelCaption).foregroundStyle(Color(nsColor: .systemTeal)).frame(width: 34)
                        } else {
                            Spacer().frame(width: 34)
                        }
                        Spacer()
                        Text(WeatherText.temperature(day.low)).font(PulseTypography.panelBody).foregroundStyle(.secondary)
                        Text(WeatherText.temperature(day.high)).font(PulseTypography.panelBody).frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Dock Cinema (tile and panel)

struct CinemaTile: View {
    let cinema: CinemaController
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if let video = cinema.current {
                    AsyncImage(url: video.thumbnailURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.black.opacity(0.5)
                    }
                    Image(systemName: cinema.pausedForAgent != nil ? "exclamationmark.bubble.fill" : (cinema.isPlaying ? "pause.fill" : "play.fill"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(cinema.pausedForAgent != nil ? theme.tone(.attention) : .white)
                        .shadow(radius: 2)
                } else if let tab = cinema.browserSuggestion {
                    AsyncImage(url: tab.video.thumbnailURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.black.opacity(0.5)
                    }
                    Image(systemName: "globe").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).shadow(radius: 2)
                } else {
                    LinearGradient(colors: [Color(red: 0.93, green: 0.18, blue: 0.2), Color(red: 0.62, green: 0.08, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 52, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottom) {
                if cinema.duration > 0 {
                    GeometryReader { proxy in
                        Capsule().fill(Color.red).frame(width: proxy.size.width * cinema.progress, height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 3)
                    .padding(.bottom, 2)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(cinema.current?.title ?? cinema.browserSuggestion?.video.title ?? tr("widget.cinema", "Dock Cinema"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(cinema.pausedForAgent != nil ? theme.tone(.attention) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.labelText)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if cinema.pausedForAgent != nil { return tr("cinema.tilePausedShort", "Paused for an agent") }
        if cinema.current == nil, let tab = cinema.browserSuggestion { return tr("cinema.browser.watching", "Open in %@", tab.browser.displayName) }
        if cinema.current == nil { return tr("cinema.dropHint", "Drop a YouTube link") }
        if !cinema.queue.isEmpty { return trp("cinema.queueCount", one: "%ld more in queue", other: "%ld more in queue", cinema.queue.count) }
        return cinema.current?.author ?? "YouTube"
    }
}

struct CinemaPanel: View {
    let cinema: CinemaController
    let theme: Theme
    let accessibility: AccessibilityOptions
    @State private var link = ""
    @State private var message: String?

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.cinema", "Dock Cinema")) {
            if let video = cinema.current {
                HStack(spacing: 10) {
                    AsyncImage(url: video.thumbnailURL) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.black.opacity(0.4) }
                        .frame(width: 112, height: 63)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(video.title ?? tr("cinema.loadingTitle", "Loading title…")).font(PulseTypography.panelHeadline).lineLimit(2)
                        if let author = video.author { Text(author).font(PulseTypography.panelCaption).foregroundStyle(.secondary) }
                        if cinema.duration > 0 {
                            Text("\(TimeMath.clock(cinema.position)) / \(TimeMath.clock(cinema.duration))")
                                .font(PulseTypography.panelCaption).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
                if case let .failed(code) = cinema.state {
                    Text(code == 101 || code == 150 ? tr("cinema.notEmbeddable", "The owner of this video does not allow it to play outside YouTube.") : tr("cinema.error", "This video could not be played."))
                        .font(PulseTypography.panelCaption).foregroundStyle(theme.tone(.failure))
                    PillButton(title: tr("cinema.openYouTube", "Open on YouTube"), symbol: "arrow.up.right.square", tint: theme.tone(.idle)) { cinema.openOnYouTube() }
                }
                HStack(spacing: 18) {
                    control("gobackward.10") { cinema.seek(by: -10) }
                    control(cinema.isPlaying ? "pause.fill" : "play.fill", size: 22) { cinema.togglePlayback() }
                    control("goforward.10") { cinema.seek(by: 10) }
                    control("forward.end.fill") { cinema.playNext() }.disabled(cinema.queue.isEmpty)
                    control(cinema.isPlayerVisible ? "pip.exit" : "pip.enter") { cinema.togglePlayerVisibility() }
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(tr("cinema.empty", "Paste or drop a YouTube link to watch it in a floating player above your work. It pauses on its own when an agent needs you."))
                    .font(PulseTypography.panelBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            browserSection
            HStack(spacing: 6) {
                TextField(tr("cinema.linkPlaceholder", "YouTube link"), text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit(playNow: true) }
                Button(tr("cinema.play", "Play")) { submit(playNow: true) }.disabled(link.isEmpty)
                Button(tr("cinema.queue", "Queue")) { submit(playNow: false) }.disabled(link.isEmpty)
            }
            .controlSize(.small)
            HStack {
                Button(tr("cinema.paste", "Paste Link from Clipboard")) {
                    message = cinema.pasteFromClipboard(playNow: cinema.current == nil) ? nil : tr("cinema.noLink", "The clipboard has no YouTube link.")
                }
                .buttonStyle(.link)
                Spacer()
                if let message { Text(message).foregroundStyle(theme.tone(.attention)) }
            }
            .font(PulseTypography.panelCaption)
            if !cinema.queue.isEmpty {
                PanelSection(title: tr("cinema.upNext", "Up next")) {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(cinema.queue) { video in queueRow(video) }
                        }
                    }
                    .frame(maxHeight: 132)
                }
            }
            Divider().opacity(0.4)
            Toggle(tr("cinema.pauseForAgents", "Pause when an agent needs me"), isOn: Binding(get: { cinema.pauseForAgents }, set: { cinema.pauseForAgents = $0 }))
            Toggle(tr("cinema.resumeAfterAgents", "Resume after I answer"), isOn: Binding(get: { cinema.resumeAfterAgents }, set: { cinema.resumeAfterAgents = $0 }))
                .disabled(!cinema.pauseForAgents)
            Toggle(tr("cinema.browser.toggle", "Show the video open in my browser"), isOn: Binding(get: { cinema.detectsBrowserVideo }, set: { cinema.detectsBrowserVideo = $0 }))
            Text(tr("cinema.privacy", "Plays with YouTube's official embedded player in privacy-enhanced mode. Nothing is sent to YouTube until you add a video."))
                .font(PulseTypography.panelCaption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onAppear { cinema.browser.detect(userInitiated: false) }
    }

    @ViewBuilder private var browserSection: some View {
        if !cinema.detectsBrowserVideo {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text(tr("cinema.browser.offer", "See which YouTube video is open in Safari or Chrome and continue it here."))
                    .font(PulseTypography.panelCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                PillButton(title: tr("cinema.browser.enable", "Detect"), symbol: "magnifyingglass", tint: theme.tone(.idle)) {
                    cinema.detectsBrowserVideo = true
                }
            }
        } else if let tab = cinema.browserSuggestion {
            PanelSection(title: tr("cinema.browser.watching", "Open in %@", tab.browser.displayName)) {
                HStack(spacing: 10) {
                    AsyncImage(url: tab.video.thumbnailURL) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.black.opacity(0.3) }
                        .frame(width: 80, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.video.title ?? tr("cinema.loadingTitle", "Loading title…")).font(PulseTypography.panelBody).lineLimit(2)
                        Text(tab.isActive ? tr("cinema.browser.selectedTab", "Selected tab") : tr("cinema.browser.backgroundTab", "Background tab"))
                            .font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    PillButton(title: tr("cinema.browser.continue", "Continue in Cinema"), symbol: "pip.enter", prominent: true, tint: theme.tone(.working)) {
                        cinema.continueFromBrowser(tab)
                    }
                    Button(tr("cinema.browser.reveal", "Go to Tab")) { cinema.browser.reveal(tab) }.buttonStyle(.link)
                    Spacer(minLength: 0)
                }
                .font(PulseTypography.panelCaption)
            }
        } else if case let .permissionDenied(browser) = cinema.browser.issue {
            HStack(spacing: 8) {
                Image(systemName: "lock").foregroundStyle(theme.tone(.attention))
                Text(tr("cinema.browser.denied", "PulseDock is not allowed to read %@ tabs.", browser.displayName))
                    .font(PulseTypography.panelCaption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(tr("cinema.browser.openSettings", "Open Settings")) { BrowserVideoDetector.openAutomationSettings() }.buttonStyle(.link)
            }
            .font(PulseTypography.panelCaption)
        } else if cinema.browser.isDetecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(tr("cinema.browser.looking", "Looking for YouTube tabs…")).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
            }
        } else {
            Label(cinema.browser.runningBrowsers.isEmpty ? tr("cinema.browser.noBrowser", "No supported browser is open.") : tr("cinema.browser.none", "No YouTube video is open in your browser."), systemImage: "globe")
                .font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
        }
    }

    private func submit(playNow: Bool) {
        if cinema.add(link: link, playNow: playNow) {
            link = ""
            message = nil
        } else {
            message = tr("cinema.invalid", "That is not a YouTube video link.")
        }
    }

    private func control(_ symbol: String, size: Double = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: size)) }
            .buttonStyle(.borderless)
    }

    private func queueRow(_ video: YouTubeVideo) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: video.thumbnailURL) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.black.opacity(0.3) }
                .frame(width: 54, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(video.title ?? video.videoID).font(PulseTypography.panelBody).lineLimit(1)
            Spacer()
            Button { cinema.play(video) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
            Button { cinema.remove(video) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }
}
