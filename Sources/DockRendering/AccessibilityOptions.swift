import AppKit
import Observation

/// System accessibility display preferences, kept up to date via NSWorkspace.
@Observable
public final class AccessibilityOptions {
    public private(set) var reduceMotion: Bool
    public private(set) var reduceTransparency: Bool
    public private(set) var increaseContrast: Bool
    public private(set) var differentiateWithoutColor: Bool

    /// Developer override used to exercise the macOS 15 material path on newer systems.
    public var forceLegacyMaterial: Bool = false

    @ObservationIgnored private var observer: NSObjectProtocol?

    public init() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func refresh() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    /// Spring to use for a frame-driven value, honouring Reduce Motion.
    public func spring(_ spring: SpringSpec) -> SpringSpec {
        reduceMotion ? MotionSprings.reduced : spring
    }
}
