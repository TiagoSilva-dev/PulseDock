import Foundation
import Testing
@testable import WidgetCore

@Suite("Widgets: timers, links, weather, conversion, clipboard, network")
struct WidgetCoreTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Countdown pauses, resumes and finishes from an injected clock")
    func countdown() {
        var timer = CountdownTimer(duration: 60)
        #expect(!timer.isRunning)
        timer.start(at: t0)
        #expect(timer.remaining(at: t0.addingTimeInterval(20)) == 40)
        timer.pause(at: t0.addingTimeInterval(20))
        #expect(timer.remaining(at: t0.addingTimeInterval(500)) == 40)
        timer.start(at: t0.addingTimeInterval(500))
        #expect(timer.isFinished(at: t0.addingTimeInterval(540)))
        #expect(timer.progress(at: t0.addingTimeInterval(530)) > 0.8)
        timer.reset(duration: 10)
        #expect(timer.remaining(at: t0) == 10)
    }

    @Test("Stopwatch accumulates across pauses; lap durations are differences")
    func stopwatch() {
        var watch = Stopwatch()
        watch.start(at: t0)
        watch.lap(at: t0.addingTimeInterval(10))
        watch.pause(at: t0.addingTimeInterval(15))
        watch.start(at: t0.addingTimeInterval(100))
        watch.lap(at: t0.addingTimeInterval(110))
        #expect(watch.elapsed(at: t0.addingTimeInterval(110)) == 25)
        #expect(watch.lapDurations == [15, 10])
    }

    @Test("Pomodoro: four focus sessions earn a long break; skipping focus does not count")
    func pomodoro() {
        var cycle = PomodoroCycle()
        #expect(cycle.phase == .focus)
        let skipped = cycle.advance(completed: false)
        #expect(skipped == false)
        #expect(cycle.phase == .shortBreak)
        cycle.advance(completed: true)
        #expect(cycle.phase == .focus)
        for _ in 0..<3 {
            let counted = cycle.advance(completed: true)
            #expect(counted)
            cycle.advance(completed: true)
        }
        #expect(cycle.focusesInSet == 3)
        let fourth = cycle.advance(completed: true)
        #expect(fourth)
        #expect(cycle.phase == .longBreak)
        cycle.advance(completed: true)
        #expect(cycle.phase == .focus)
        #expect(cycle.focusesInSet == 0)
    }

    @Test("Time progress and day counting use the calendar")
    func timeMath() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12))!
        #expect(abs(TimeMath.progress(.day, at: noon, calendar: calendar) - 0.5) < 0.0001)
        let newYear = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        #expect(TimeMath.daysUntil(newYear, from: noon, calendar: calendar) == 75)
        #expect(TimeMath.daysUntil(noon, from: noon, calendar: calendar) == 0)
        #expect(TimeMath.clock(65) == "01:05")
        #expect(TimeMath.clock(3725) == "1:02:05")
        #expect(TimeMath.dayKey(noon, calendar: calendar) == "2026-10-18")
    }

    @Test("YouTube links: every common shape parses; other sites and bad IDs do not")
    func youtube() {
        #expect(YouTubeLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.videoID == "dQw4w9WgXcQ")
        #expect(YouTubeLink.parse("youtube.com/watch?v=dQw4w9WgXcQ&list=PL123")?.videoID == "dQw4w9WgXcQ")
        #expect(YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ?t=1m30s")?.start == 90)
        #expect(YouTubeLink.parse("https://www.youtube.com/shorts/dQw4w9WgXcQ")?.videoID == "dQw4w9WgXcQ")
        #expect(YouTubeLink.parse("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?start=42")?.start == 42)
        #expect(YouTubeLink.parse("https://music.youtube.com/watch?v=dQw4w9WgXcQ")?.videoID == "dQw4w9WgXcQ")
        #expect(YouTubeLink.parse("https://m.youtube.com/live/dQw4w9WgXcQ")?.videoID == "dQw4w9WgXcQ")
        #expect(YouTubeLink.parse("https://vimeo.com/12345") == nil)
        #expect(YouTubeLink.parse("https://www.youtube.com/watch?v=short") == nil)
        #expect(YouTubeLink.parse("https://www.youtube.com/@channel") == nil)
        #expect(YouTubeLink.parse("https://evil.example/watch?v=dQw4w9WgXcQ") == nil)
        #expect(YouTubeLink.parseTime("1h2m3s") == 3723)
        #expect(YouTubeLink.parseTime("abc") == nil)
        let video = YouTubeVideo(videoID: "dQw4w9WgXcQ", start: 30)
        #expect(video.watchURL?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30s")
    }

    @Test("Browser video detection: parses script output, cleans titles and picks the watched tab")
    func browserVideo() {
        let output = """
        1\t1\tfalse\thttps://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s\t(3) Never Gonna Give You Up - YouTube
        1\t2\ttrue\thttps://www.youtube.com/watch?v=okWVDI1NwQQ\tNo meu bairro - YouTube
        2\t1\ttrue\thttps://www.youtube.com/@channel\tChannel - YouTube
        garbage line
        """
        let tabs = BrowserVideoScript.parse(output, browser: .chrome)
        #expect(tabs.count == 2)
        #expect(tabs[0].video.start == 42)
        #expect(tabs[0].video.title == "Never Gonna Give You Up")
        #expect(tabs[1].isActive && tabs[1].video.title == "No meu bairro")
        #expect(BrowserVideoScript.best(tabs, recency: [.chrome])?.video.videoID == "okWVDI1NwQQ")

        // A selected tab beats a background one; then the most recently used browser wins.
        let safari = BrowserVideoTab(browser: .safari, window: 1, tab: 4, isActive: true, video: YouTubeVideo(videoID: "aaaaaaaaaaa"))
        #expect(BrowserVideoScript.best(tabs + [safari], recency: [.safari, .chrome])?.browser == .safari)
        #expect(BrowserVideoScript.best(tabs + [safari], recency: [.chrome, .safari])?.browser == .chrome)
        #expect(BrowserVideoScript.best([], recency: []) == nil)

        #expect(BrowserVideoScript.cleanTitle("YouTube") == nil)
        #expect(BrowserVideoScript.cleanTitle("Mix - YouTube Music") == "Mix")
        // The privacy filter lives inside the AppleScript, so other tabs' URLs never leave it.
        for browser in BrowserKind.allCases {
            #expect(BrowserVideoScript.listSource(for: browser).contains("youtube.com/"))
        }
        #expect(BrowserVideoScript.handOffSource(for: safari)?.contains("do JavaScript") == true)
    }

    @Test("Browser scripts compile against each installed browser's dictionary (no events sent)")
    func browserScriptsCompile() throws {
        let installed = BrowserKind.allCases.filter { browser in
            ["/Applications", "/System/Volumes/Preboot/Cryptexes/App/System/Applications"].contains { root in
                FileManager.default.fileExists(atPath: "\(root)/\(Self.appName(browser)).app")
            }
        }
        for browser in installed {
            let tab = BrowserVideoTab(browser: browser, window: 1, tab: 2, isActive: true, video: YouTubeVideo(videoID: "dQw4w9WgXcQ"))
            let sources = [BrowserVideoScript.listSource(for: browser), BrowserVideoScript.revealSource(for: tab)] + [BrowserVideoScript.handOffSource(for: tab)].compactMap { $0 }
            for source in sources {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
                process.arguments = ["-o", FileManager.default.temporaryDirectory.appendingPathComponent("pulsedock-\(UUID().uuidString).scpt").path, "-e", source]
                let errors = Pipe()
                process.standardError = errors
                try process.run()
                process.waitUntilExit()
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                #expect(process.terminationStatus == 0, "\(browser.displayName): \(message)")
            }
        }
    }

    static func appName(_ browser: BrowserKind) -> String {
        switch browser {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .brave: "Brave Browser"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc"
        }
    }

    @Test("Open-Meteo forecast and geocoding responses decode")
    func weather() throws {
        let forecast = """
        {"utc_offset_seconds":-10800,
         "current":{"temperature_2m":24.6,"apparent_temperature":25.1,"weather_code":2,"is_day":1,"relative_humidity_2m":60,"wind_speed_10m":11.4},
         "hourly":{"time":["2027-01-15T08:00","2027-01-15T09:00"],"temperature_2m":[20.1,21.3],"weather_code":[1,3]},
         "daily":{"time":["2027-01-15","2027-01-16"],"weather_code":[2,61],"temperature_2m_max":[28.0,24.5],"temperature_2m_min":[18.2,17.9],"precipitation_probability_max":[10,null]}}
        """
        let now = ISO8601DateFormatter().date(from: "2027-01-15T10:00:00Z")!
        let report = try #require(OpenMeteo.parseForecast(Data(forecast.utf8), now: now))
        #expect(report.temperature == 24.6)
        #expect(report.days.count == 2)
        #expect(report.days[0].precipitationChance == 10)
        #expect(report.days[1].precipitationChance == nil)
        #expect(report.hours.count == 2)
        #expect(WeatherCondition(code: report.code) == .partlyCloudy)
        #expect(WeatherCondition(code: 95) == .thunderstorm)
        #expect(OpenMeteo.parseForecast(Data("{}".utf8)) == nil)

        let places = OpenMeteo.parsePlaces(Data(#"{"results":[{"name":"São Paulo","latitude":-23.55,"longitude":-46.63,"admin1":"São Paulo","country":"Brasil"}]}"#.utf8))
        #expect(places.first?.region == "São Paulo, Brasil")
        let url = try #require(OpenMeteo.forecastURL(places[0], fahrenheit: true))
        #expect(url.absoluteString.contains("temperature_unit=fahrenheit"))
        #expect(url.absoluteString.contains("latitude=-23.5500"))
    }

    @Test("Unit conversion within a family; parsing follows the locale")
    func conversion() throws {
        let km = try #require(UnitConverter.convert(1, from: UnitLength.miles, to: UnitLength.kilometers))
        #expect(abs(km - 1.609344) < 0.000001)
        let fahrenheit = try #require(UnitConverter.convert(100, from: UnitTemperature.celsius, to: UnitTemperature.fahrenheit))
        #expect(abs(fahrenheit - 212) < 0.0001)
        #expect(UnitConverter.convert(1, from: UnitLength.meters, to: UnitMass.grams) == nil)
        #expect(UnitConverter.parse("1,5", locale: Locale(identifier: "pt_BR")) == 1.5)
        #expect(UnitConverter.parse("1.5", locale: Locale(identifier: "en_US")) == 1.5)
        for family in ConversionFamily.allCases { #expect(family.units.count >= 3) }
    }

    @Test("Clipboard: concealed items are ignored, duplicates move up, history is bounded")
    func clipboard() {
        #expect(ClipboardPolicy.shouldIgnore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!ClipboardPolicy.shouldIgnore(types: ["public.utf8-plain-text"]))
        var items: [ClipboardItem] = []
        items = ClipboardPolicy.inserting(ClipboardItem(content: .text("a"), isPinned: true), into: items)
        for index in 0..<60 { items = ClipboardPolicy.inserting(ClipboardItem(content: .text("x\(index)")), into: items) }
        #expect(items.count == ClipboardPolicy.maxItems + 1)
        #expect(items.contains { $0.isPinned && $0.content == .text("a") })
        items = ClipboardPolicy.inserting(ClipboardItem(content: .text("a")), into: items)
        #expect(items.first?.content == .text("a"))
        #expect(items.first?.isPinned == true)
        #expect(items.filter { $0.content == .text("a") }.count == 1)
    }

    @Test("Network rate: bytes per second, counter resets give zero")
    func networkRate() {
        let old = InterfaceCounters(received: 1_000, sent: 500)
        let new = InterfaceCounters(received: 3_000, sent: 1_500)
        let rate = InterfaceCounters.rate(from: old, to: new, seconds: 2)
        #expect(rate.down == 1_000)
        #expect(rate.up == 500)
        let reset = InterfaceCounters.rate(from: new, to: old, seconds: 2)
        #expect(reset.down == 0 && reset.up == 0)
        // Reading the real counters never crashes.
        _ = InterfaceCounters.read()
    }

    @Test("Emoji skin tones apply only to emoji that accept them")
    func emoji() {
        #expect(EmojiCatalog.applying(tone: 3, to: "👍") == "👍🏽")
        #expect(EmojiCatalog.applying(tone: 3, to: "😀") == "😀")
        #expect(EmojiCatalog.applying(tone: 0, to: "👍") == "👍")
        #expect(EmojiCatalog.ranked(["🔥": 3, "👍": 5, "😂": 3], limit: 2) == ["👍", "🔥"])
        for group in EmojiCatalog.Group.allCases { #expect(!group.emoji.isEmpty) }
    }
}
