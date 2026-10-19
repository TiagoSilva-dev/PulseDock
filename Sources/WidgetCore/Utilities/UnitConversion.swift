import Foundation

/// Unit families of the Converter widget, built on Foundation's `Measurement`, so symbols and
/// names come localized from the system.
public nonisolated enum ConversionFamily: String, Codable, CaseIterable, Sendable {
    case length, mass, temperature, volume, speed, data, time, area

    public var units: [Dimension] {
        switch self {
        case .length: [UnitLength.millimeters, UnitLength.centimeters, UnitLength.meters, UnitLength.kilometers, UnitLength.inches, UnitLength.feet, UnitLength.yards, UnitLength.miles]
        case .mass: [UnitMass.grams, UnitMass.kilograms, UnitMass.ounces, UnitMass.pounds, UnitMass.stones, UnitMass.metricTons]
        case .temperature: [UnitTemperature.celsius, UnitTemperature.fahrenheit, UnitTemperature.kelvin]
        case .volume: [UnitVolume.milliliters, UnitVolume.liters, UnitVolume.cups, UnitVolume.fluidOunces, UnitVolume.gallons, UnitVolume.imperialGallons]
        case .speed: [UnitSpeed.kilometersPerHour, UnitSpeed.milesPerHour, UnitSpeed.metersPerSecond, UnitSpeed.knots]
        case .data: [UnitInformationStorage.bytes, UnitInformationStorage.kilobytes, UnitInformationStorage.megabytes, UnitInformationStorage.gigabytes, UnitInformationStorage.terabytes, UnitInformationStorage.bits, UnitInformationStorage.megabits, UnitInformationStorage.gigabits]
        case .time: [UnitDuration.seconds, UnitDuration.minutes, UnitDuration.hours, UnitDuration.milliseconds]
        case .area: [UnitArea.squareMeters, UnitArea.squareKilometers, UnitArea.hectares, UnitArea.squareFeet, UnitArea.acres, UnitArea.squareMiles]
        }
    }

    public var symbol: String {
        switch self {
        case .length: "ruler"
        case .mass: "scalemass"
        case .temperature: "thermometer.medium"
        case .volume: "drop"
        case .speed: "speedometer"
        case .data: "externaldrive"
        case .time: "clock"
        case .area: "square.dashed"
        }
    }
}

public nonisolated enum UnitConverter {
    public static func convert(_ value: Double, from source: Dimension, to target: Dimension) -> Double? {
        guard type(of: source) == type(of: target) else { return nil }
        return Measurement(value: value, unit: source).converted(to: target).value
    }

    /// Parses "1,5" and "1.5" (the user's decimal separator first).
    public static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        if let number = formatter.number(from: trimmed) { return number.doubleValue }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    public static func format(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumSignificantDigits = 8
        formatter.usesSignificantDigits = abs(value) < 0.001 || abs(value) >= 1e9
        if !formatter.usesSignificantDigits { formatter.maximumFractionDigits = 4 }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func unitName(_ unit: Dimension, locale: Locale = .current) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        return formatter.string(from: unit)
    }
}
