import Foundation
import SwiftUI

/// The motion vocabulary of PulseDock. Durations follow the design brief:
/// micro feedback 100–160 ms, hover 140–220 ms, panels 220–320 ms,
/// environment changes 250–400 ms, ambient pulse 1.5–2.5 s.
public nonisolated enum MotionClass: Sendable, CaseIterable {
    case micro
    case hover
    case panel
    case environment
    case ambient

    public var duration: Double {
        switch self {
        case .micro: 0.13
        case .hover: 0.18
        case .panel: 0.27
        case .environment: 0.33
        case .ambient: 2.0
        }
    }
}

/// Springs used by values the dock drives frame-by-frame.
public nonisolated enum MotionSprings {
    /// Pointer smoothing: critically damped, fast enough to feel 1:1.
    public static let pointer = SpringSpec(response: 0.09, dampingFraction: 1.0)
    /// Magnification amplitude when the pointer enters or leaves the dock.
    public static let magnification = SpringSpec(response: 0.22, dampingFraction: 0.86)
    /// Agent Pulse island growing or shrinking with its content.
    public static let island = SpringSpec(response: 0.34, dampingFraction: 0.84)
    /// Auto-hide slide.
    public static let autoHide = SpringSpec(response: 0.30, dampingFraction: 0.94)
    /// Icons making room while reordering.
    public static let reorder = SpringSpec(response: 0.24, dampingFraction: 0.84)
    /// Click feedback.
    public static let press = SpringSpec(response: 0.14, dampingFraction: 0.72)
    /// Used for everything when Reduce Motion is on: no overshoot, near-instant.
    public static let reduced = SpringSpec(response: 0.08, dampingFraction: 1.0)
}

/// SwiftUI animations for declarative transitions (panels, fades, state chips).
public enum Motion {
    public static func animation(_ motion: MotionClass, reduceMotion: Bool) -> Animation? {
        if reduceMotion {
            return motion == .ambient ? nil : .easeOut(duration: 0.12)
        }
        switch motion {
        case .micro: return .spring(response: 0.18, dampingFraction: 0.78)
        case .hover: return .spring(response: 0.22, dampingFraction: 0.84)
        case .panel: return .spring(response: 0.32, dampingFraction: 0.86)
        case .environment: return .spring(response: 0.38, dampingFraction: 0.9)
        case .ambient: return .easeInOut(duration: MotionClass.ambient.duration).repeatForever(autoreverses: true)
        }
    }
}
