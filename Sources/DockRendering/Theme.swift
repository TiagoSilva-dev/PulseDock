import AppKit
import SwiftUI

public enum ThemeID: String, CaseIterable, Codable, Sendable, Identifiable {
    case nativeGlass
    case midnight
    case aurora

    public var id: String { rawValue }
}

/// Semantic tone of a status indicator. Agent states map onto these in the app layer;
/// tones are always paired with a symbol or text so colour is never the only signal.
public nonisolated enum StatusTone: String, Sendable, CaseIterable {
    case working
    case attention
    case success
    case failure
    case idle
    case unknown
    case offline
}

public nonisolated enum GlassVariant: Sendable, Equatable {
    case regular
    case clear
}

/// A complete visual theme. Themes only describe appearance; geometry lives in
/// `DockMetrics` and motion in `Motion`.
public struct Theme: Identifiable {
    public let id: ThemeID
    public let glass: GlassVariant
    public let glassTint: Color?
    public let legacyMaterial: NSVisualEffectView.Material
    public let legacyTint: Color
    public let forcedColorScheme: ColorScheme?
    /// Fill used when Reduce Transparency is on.
    public let opaqueFill: Color
    public let borderTop: Color
    public let borderBottom: Color
    public let highlight: Color
    public let shadowColor: Color
    public let shadowRadius: Double
    public let shadowY: Double
    public let divider: Color
    public let runningIndicator: Color
    public let labelText: Color
    public let islandFill: Color
    public let islandStroke: Color
    /// 0 = no ambient light, 1 = full Aurora treatment. Ambient light is always local to
    /// the Agent Pulse island and only shown while something relevant happens.
    public let ambientIntensity: Double
    public let accentGradient: [Color]
    private let tones: [StatusTone: Color]

    public func tone(_ tone: StatusTone) -> Color {
        tones[tone] ?? .secondary
    }

    @available(macOS 26.0, *)
    public func swiftUIGlass(interactive: Bool = false, clear: Bool = false) -> Glass {
        var glass: Glass = (self.glass == .clear || clear) ? .clear : .regular
        if let glassTint { glass = glass.tint(glassTint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    public static func theme(for id: ThemeID) -> Theme {
        switch id {
        case .nativeGlass: .nativeGlass
        case .midnight: .midnight
        case .aurora: .aurora
        }
    }
}

// MARK: - Palettes

extension Theme {
    /// The default: as close as possible to the native macOS language.
    public static let nativeGlass = Theme(
        id: .nativeGlass,
        glass: .regular,
        glassTint: nil,
        legacyMaterial: .popover,
        legacyTint: .clear,
        forcedColorScheme: nil,
        opaqueFill: .dynamic(light: NSColor(white: 0.96, alpha: 1), dark: NSColor(white: 0.16, alpha: 1)),
        borderTop: .dynamic(light: NSColor(white: 1, alpha: 0.55), dark: NSColor(white: 1, alpha: 0.20)),
        borderBottom: .dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.06)),
        highlight: .dynamic(light: NSColor(white: 1, alpha: 0.18), dark: NSColor(white: 1, alpha: 0.06)),
        shadowColor: .dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 0, alpha: 0.30)),
        shadowRadius: 14,
        shadowY: 5,
        divider: .dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.16)),
        runningIndicator: .dynamic(light: NSColor(white: 0.12, alpha: 0.78), dark: NSColor(white: 1, alpha: 0.82)),
        labelText: .primary,
        islandFill: .dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.06)),
        islandStroke: .dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08)),
        ambientIntensity: 0.25,
        accentGradient: [Color(nsColor: .systemBlue), Color(nsColor: .systemTeal)],
        tones: [
            .working: .dynamic(light: NSColor(srgbRed: 0.0, green: 0.45, blue: 0.95, alpha: 1), dark: NSColor(srgbRed: 0.25, green: 0.6, blue: 1.0, alpha: 1)),
            .attention: .dynamic(light: NSColor(srgbRed: 0.80, green: 0.47, blue: 0.0, alpha: 1), dark: NSColor(srgbRed: 1.0, green: 0.70, blue: 0.16, alpha: 1)),
            .success: .dynamic(light: NSColor(srgbRed: 0.13, green: 0.58, blue: 0.27, alpha: 1), dark: NSColor(srgbRed: 0.26, green: 0.84, blue: 0.45, alpha: 1)),
            .failure: .dynamic(light: NSColor(srgbRed: 0.84, green: 0.16, blue: 0.16, alpha: 1), dark: NSColor(srgbRed: 1.0, green: 0.38, blue: 0.34, alpha: 1)),
            .idle: .dynamic(light: NSColor(white: 0.35, alpha: 1), dark: NSColor(white: 0.72, alpha: 1)),
            .unknown: .dynamic(light: NSColor(white: 0.55, alpha: 1), dark: NSColor(white: 0.52, alpha: 1)),
            .offline: .dynamic(light: NSColor(white: 0.66, alpha: 1), dark: NSColor(white: 0.40, alpha: 1)),
        ]
    )

    /// Graphite glass for people who live in dark mode. Always dark, crisper indicators,
    /// reflections reduced to almost nothing.
    public static let midnight = Theme(
        id: .midnight,
        glass: .regular,
        glassTint: Color(.sRGB, red: 0.05, green: 0.055, blue: 0.07, opacity: 0.58),
        legacyMaterial: .hudWindow,
        legacyTint: Color(.sRGB, red: 0.04, green: 0.045, blue: 0.06, opacity: 0.42),
        forcedColorScheme: .dark,
        opaqueFill: Color(.sRGB, red: 0.09, green: 0.095, blue: 0.11, opacity: 1),
        borderTop: Color(white: 1, opacity: 0.16),
        borderBottom: Color(white: 1, opacity: 0.04),
        highlight: Color(white: 1, opacity: 0.03),
        shadowColor: Color(white: 0, opacity: 0.42),
        shadowRadius: 16,
        shadowY: 6,
        divider: Color(white: 1, opacity: 0.13),
        runningIndicator: Color(white: 1, opacity: 0.92),
        labelText: Color(white: 0.96),
        islandFill: Color(white: 1, opacity: 0.055),
        islandStroke: Color(white: 1, opacity: 0.09),
        ambientIntensity: 0.45,
        accentGradient: [Color(.sRGB, red: 0.33, green: 0.62, blue: 1.0), Color(.sRGB, red: 0.5, green: 0.85, blue: 1.0)],
        tones: [
            .working: Color(.sRGB, red: 0.36, green: 0.66, blue: 1.0),
            .attention: Color(.sRGB, red: 1.0, green: 0.72, blue: 0.25),
            .success: Color(.sRGB, red: 0.30, green: 0.87, blue: 0.53),
            .failure: Color(.sRGB, red: 1.0, green: 0.42, blue: 0.40),
            .idle: Color(white: 0.70),
            .unknown: Color(white: 0.48),
            .offline: Color(white: 0.36),
        ]
    )

    /// Translucent glass with restrained blue, violet and cyan accents. Its light responds
    /// to agent states around the Agent Pulse island instead of glowing permanently.
    public static let aurora = Theme(
        id: .aurora,
        glass: .regular,
        glassTint: Color(.sRGB, red: 0.30, green: 0.25, blue: 0.75, opacity: 0.10),
        legacyMaterial: .fullScreenUI,
        legacyTint: Color(.sRGB, red: 0.25, green: 0.22, blue: 0.62, opacity: 0.10),
        forcedColorScheme: nil,
        opaqueFill: .dynamic(light: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.98, alpha: 1), dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.16, alpha: 1)),
        borderTop: .dynamic(light: NSColor(srgbRed: 0.75, green: 0.78, blue: 1.0, alpha: 0.65), dark: NSColor(srgbRed: 0.62, green: 0.70, blue: 1.0, alpha: 0.30)),
        borderBottom: .dynamic(light: NSColor(srgbRed: 0.45, green: 0.35, blue: 0.85, alpha: 0.14), dark: NSColor(srgbRed: 0.55, green: 0.40, blue: 1.0, alpha: 0.10)),
        highlight: .dynamic(light: NSColor(white: 1, alpha: 0.20), dark: NSColor(srgbRed: 0.75, green: 0.82, blue: 1.0, alpha: 0.07)),
        shadowColor: .dynamic(light: NSColor(srgbRed: 0.18, green: 0.16, blue: 0.45, alpha: 0.16), dark: NSColor(white: 0, alpha: 0.36)),
        shadowRadius: 16,
        shadowY: 6,
        divider: .dynamic(light: NSColor(srgbRed: 0.35, green: 0.32, blue: 0.70, alpha: 0.18), dark: NSColor(srgbRed: 0.75, green: 0.78, blue: 1.0, alpha: 0.16)),
        runningIndicator: .dynamic(light: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.55, alpha: 0.80), dark: NSColor(srgbRed: 0.80, green: 0.92, blue: 1.0, alpha: 0.90)),
        labelText: .primary,
        islandFill: .dynamic(light: NSColor(srgbRed: 0.40, green: 0.38, blue: 0.85, alpha: 0.06), dark: NSColor(srgbRed: 0.65, green: 0.70, blue: 1.0, alpha: 0.07)),
        islandStroke: .dynamic(light: NSColor(srgbRed: 0.40, green: 0.38, blue: 0.85, alpha: 0.12), dark: NSColor(srgbRed: 0.65, green: 0.75, blue: 1.0, alpha: 0.14)),
        ambientIntensity: 1.0,
        accentGradient: [
            Color(.sRGB, red: 0.35, green: 0.55, blue: 1.0),
            Color(.sRGB, red: 0.62, green: 0.42, blue: 1.0),
            Color(.sRGB, red: 0.30, green: 0.85, blue: 0.95),
        ],
        // Aurora follows the system appearance, so its state colours need light variants:
        // the luminous dark-mode tones drop below readable contrast on light glass.
        tones: [
            .working: .dynamic(light: NSColor(srgbRed: 0.10, green: 0.38, blue: 0.90, alpha: 1), dark: NSColor(srgbRed: 0.38, green: 0.68, blue: 1.0, alpha: 1)),
            .attention: .dynamic(light: NSColor(srgbRed: 0.80, green: 0.45, blue: 0.0, alpha: 1), dark: NSColor(srgbRed: 1.0, green: 0.71, blue: 0.28, alpha: 1)),
            .success: .dynamic(light: NSColor(srgbRed: 0.06, green: 0.54, blue: 0.36, alpha: 1), dark: NSColor(srgbRed: 0.30, green: 0.88, blue: 0.64, alpha: 1)),
            .failure: .dynamic(light: NSColor(srgbRed: 0.82, green: 0.16, blue: 0.24, alpha: 1), dark: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.45, alpha: 1)),
            .idle: .dynamic(light: NSColor(white: 0.38, alpha: 1), dark: NSColor(white: 0.70, alpha: 1)),
            .unknown: .dynamic(light: NSColor(white: 0.55, alpha: 1), dark: NSColor(white: 0.50, alpha: 1)),
            .offline: .dynamic(light: NSColor(white: 0.65, alpha: 1), dark: NSColor(white: 0.38, alpha: 1)),
        ]
    )
}

// MARK: - Dynamic colours

extension Color {
    /// A colour that resolves differently in light and dark appearances.
    public static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
