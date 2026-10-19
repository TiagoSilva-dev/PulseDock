import AppKit
import SwiftUI

/// "Pulse Glass": the material of the dock bar and of every surface anchored to it.
///
/// - macOS 26+: native Liquid Glass (`glassEffect`), optionally tinted by the theme.
/// - macOS 15: `NSVisualEffectView` blending behind the window.
/// - Reduce Transparency: an opaque fill with the same border and depth.
///
/// A hairline border, a faint top highlight and a soft shadow give depth without glow.
/// The backdrop always comes from the window server; nothing captures the screen.
public struct PulseGlassSurface: View {
    /// User preference on top of the system setting (Appearance › Transparency).
    public enum Opacity: Sendable {
        case clear
        case standard
        case opaque
    }

    /// How strongly the surface guarantees text contrast over an arbitrary backdrop.
    public enum Legibility: Sendable {
        /// Bars of icons with little text: the glass alone.
        case bar
        /// Panels, popovers and labels: an adaptive scrim between the glass and the content.
        /// Liquid Glass darkens itself over dark windows, but content drawn above it keeps
        /// the colours of the interface appearance; the scrim keeps dark text readable over
        /// dark backdrops in light mode (and light text over bright ones in dark mode).
        case content
    }

    public var theme: Theme
    public var cornerRadius: Double
    public var accessibility: AccessibilityOptions
    public var showsShadow: Bool
    public var opacity: Opacity
    /// 0 hides the border, 1 is the theme default, >1 strengthens it.
    public var borderEmphasis: Double
    public var legibility: Legibility
    @Environment(\.colorScheme) private var colorScheme

    public init(theme: Theme, cornerRadius: Double, accessibility: AccessibilityOptions, showsShadow: Bool = true,
                opacity: Opacity = .standard, borderEmphasis: Double = 1, legibility: Legibility = .bar) {
        self.theme = theme
        self.cornerRadius = cornerRadius
        self.accessibility = accessibility
        self.showsShadow = showsShadow
        self.opacity = opacity
        self.borderEmphasis = borderEmphasis
        self.legibility = legibility
    }

    private var isOpaque: Bool { accessibility.reduceTransparency || opacity == .opaque }

    private var scrim: Color {
        let dark = colorScheme == .dark
        switch opacity {
        case .clear: return dark ? Color.black.opacity(0.18) : Color.white.opacity(0.40)
        case .standard, .opaque: return dark ? Color.black.opacity(0.30) : Color.white.opacity(0.62)
        }
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let borderWidth: Double = accessibility.increaseContrast ? 1.5 : 1
        ZStack {
            material(shape: shape)
            if legibility == .content, !isOpaque {
                shape.fill(scrim).allowsHitTesting(false)
            }
            shape
                .fill(LinearGradient(colors: [theme.highlight, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)))
                .allowsHitTesting(false)
            if borderEmphasis > 0 || accessibility.increaseContrast {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: accessibility.increaseContrast
                                ? [Color.primary.opacity(0.45), Color.primary.opacity(0.3)]
                                : [theme.borderTop, theme.borderBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: borderWidth
                    )
                    .opacity(accessibility.increaseContrast ? 1 : min(1, borderEmphasis))
                    .brightness(borderEmphasis > 1 ? 0.08 * (borderEmphasis - 1) : 0)
                    .allowsHitTesting(false)
            }
        }
        .compositingGroup()
        .shadow(color: showsShadow ? theme.shadowColor : .clear, radius: theme.shadowRadius, x: 0, y: theme.shadowY)
    }

    @ViewBuilder
    private func material(shape: RoundedRectangle) -> some View {
        if isOpaque {
            shape.fill(theme.opaqueFill)
        } else if #available(macOS 26.0, *), !accessibility.forceLegacyMaterial {
            Color.clear.glassEffect(opacity == .clear ? theme.swiftUIGlass(clear: true) : theme.swiftUIGlass(), in: shape)
        } else {
            ZStack {
                VisualEffectBackground(material: theme.legacyMaterial, forceDark: theme.forcedColorScheme == .dark)
                shape.fill(theme.legacyTint)
            }
            .clipShape(shape)
        }
    }
}

/// Wraps `NSVisualEffectView` for the macOS 15 material path.
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    public var forceDark: Bool

    public init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow, forceDark: Bool = false) {
        self.material = material
        self.blendingMode = blendingMode
        self.forceDark = forceDark
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.isEmphasized = false
        update(view)
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        update(view)
    }

    private func update(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.appearance = forceDark ? NSAppearance(named: .darkAqua) : nil
    }
}
