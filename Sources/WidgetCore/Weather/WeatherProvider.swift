import Foundation
import Observation

/// A place chosen by the user (by name; PulseDock never asks for the Mac's location).
public nonisolated struct WeatherPlace: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(latitude),\(longitude)" }
    public var name: String
    public var region: String?
    public var latitude: Double
    public var longitude: Double

    public init(name: String, region: String? = nil, latitude: Double, longitude: Double) {
        self.name = name
        self.region = region
        self.latitude = latitude
        self.longitude = longitude
    }
}

public nonisolated struct WeatherReport: Codable, Hashable, Sendable {
    public struct Day: Codable, Hashable, Sendable, Identifiable {
        public var id: Date { date }
        public var date: Date
        public var code: Int
        public var high: Double
        public var low: Double
        public var precipitationChance: Int?
    }

    public struct Hour: Codable, Hashable, Sendable, Identifiable {
        public var id: Date { date }
        public var date: Date
        public var temperature: Double
        public var code: Int
    }

    public var temperature: Double
    public var apparentTemperature: Double
    public var code: Int
    public var isDay: Bool
    public var humidity: Int?
    public var windSpeed: Double?
    public var days: [Day]
    public var hours: [Hour]
    public var fetchedAt: Date
}

/// WMO weather interpretation codes (used by Open-Meteo) mapped to SF Symbols and a
/// condition key the app localizes.
public nonisolated enum WeatherCondition: String, Sendable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, freezingRain, snow, showers, thunderstorm

    public init(code: Int) {
        switch code {
        case 0: self = .clear
        case 1, 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57, 66, 67: self = .freezingRain
        case 61, 63, 65: self = .rain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 80, 81, 82: self = .showers
        case 95, 96, 99: self = .thunderstorm
        default: self = .cloudy
        }
    }

    public func symbol(isDay: Bool = true) -> String {
        switch self {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .freezingRain: "cloud.sleet.fill"
        case .snow: "cloud.snow.fill"
        case .showers: "cloud.heavyrain.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        }
    }
}

public nonisolated enum OpenMeteo {
    public static func searchURL(_ query: String, language: String) -> URL? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    public static func forecastURL(_ place: WeatherPlace, fahrenheit: Bool) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "forecast_days", value: "6"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        return components?.url
    }

    public static func parsePlaces(_ data: Data) -> [WeatherPlace] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let name = result["name"] as? String,
                  let latitude = result["latitude"] as? Double,
                  let longitude = result["longitude"] as? Double else { return nil }
            let region = [result["admin1"] as? String, result["country"] as? String].compactMap { $0 }.joined(separator: ", ")
            return WeatherPlace(name: name, region: region.isEmpty ? nil : region, latitude: latitude, longitude: longitude)
        }
    }

    /// Parses a forecast response. Times are local to the place ("timezone=auto"), given as
    /// "2026-10-18T14:00" plus `utc_offset_seconds`.
    public static func parseForecast(_ data: Data, now: Date = Date()) -> WeatherReport? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (current["weather_code"] as? NSNumber)?.intValue else { return nil }
        let offset = (object["utc_offset_seconds"] as? NSNumber)?.intValue ?? 0
        let timeZone = TimeZone(secondsFromGMT: offset) ?? .current
        func date(_ text: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = text.count > 10 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
            return formatter.date(from: text)
        }
        var days: [WeatherReport.Day] = []
        if let daily = object["daily"] as? [String: Any],
           let times = daily["time"] as? [String],
           let codes = daily["weather_code"] as? [NSNumber],
           let highs = daily["temperature_2m_max"] as? [NSNumber],
           let lows = daily["temperature_2m_min"] as? [NSNumber] {
            let rain = daily["precipitation_probability_max"] as? [Any]
            for index in times.indices where index < codes.count && index < highs.count && index < lows.count {
                guard let day = date(times[index]) else { continue }
                let chance = (rain?[safe: index] as? NSNumber)?.intValue
                days.append(.init(date: day, code: codes[index].intValue, high: highs[index].doubleValue, low: lows[index].doubleValue, precipitationChance: chance))
            }
        }
        var hours: [WeatherReport.Hour] = []
        if let hourly = object["hourly"] as? [String: Any],
           let times = hourly["time"] as? [String],
           let temps = hourly["temperature_2m"] as? [NSNumber],
           let codes = hourly["weather_code"] as? [NSNumber] {
            for index in times.indices where index < temps.count && index < codes.count {
                guard let hour = date(times[index]), hour >= now.addingTimeInterval(-3600) else { continue }
                hours.append(.init(date: hour, temperature: temps[index].doubleValue, code: codes[index].intValue))
                if hours.count == 12 { break }
            }
        }
        return WeatherReport(
            temperature: temperature,
            apparentTemperature: (current["apparent_temperature"] as? NSNumber)?.doubleValue ?? temperature,
            code: code,
            isDay: ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1,
            humidity: (current["relative_humidity_2m"] as? NSNumber)?.intValue,
            windSpeed: (current["wind_speed_10m"] as? NSNumber)?.doubleValue,
            days: days,
            hours: hours,
            fetchedAt: now
        )
    }
}

extension Array {
    nonisolated subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Fetches the forecast for the chosen place every 30 minutes while visible. Nothing is sent
/// until the user picks a place; the request carries only coordinates (no identifiers).
@Observable
public final class WeatherProvider {
    public private(set) var report: WeatherReport?
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    public var place: WeatherPlace? {
        didSet { if place != oldValue { report = nil; refresh(force: true) } }
    }
    public var fahrenheit = false {
        didSet { if fahrenheit != oldValue { refresh(force: true) } }
    }
    public var isVisible = false {
        didSet { if isVisible != oldValue { reschedule() } }
    }

    @ObservationIgnored private var timer: Timer?
    private static let refreshInterval: TimeInterval = 30 * 60

    public init() {}

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isVisible else { return }
        refresh(force: false)
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func refresh(force: Bool) {
        guard let place, !isLoading else { return }
        if !force, let report, Date().timeIntervalSince(report.fetchedAt) < Self.refreshInterval { return }
        guard let url = OpenMeteo.forecastURL(place, fahrenheit: fahrenheit) else { return }
        isLoading = true
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let parsed = OpenMeteo.parseForecast(data) {
                    report = parsed
                    lastError = nil
                } else {
                    lastError = "parse"
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public static func search(_ query: String) async -> [WeatherPlace] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        guard query.trimmingCharacters(in: .whitespaces).count >= 2,
              let url = OpenMeteo.searchURL(query, language: language),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        return OpenMeteo.parsePlaces(data)
    }
}
