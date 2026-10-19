import Foundation

/// Parameters of the organic magnification curve.
public nonisolated struct MagnificationParameters: Sendable, Equatable {
    /// Scale of the icon directly under the cursor (1.0 disables magnification).
    public var maxScale: Double
    /// Distance (in base, unmagnified points) at which the influence of the cursor reaches zero.
    public var radius: Double

    public init(maxScale: Double, radius: Double) {
        self.maxScale = max(1, maxScale)
        self.radius = max(1, radius)
    }

    public static let disabled = MagnificationParameters(maxScale: 1, radius: 1)
}

/// The magnification density is a raised-cosine bell centred on the cursor:
///
///     m(t) = 1 + k · (1 + cos(π t / R)) / 2      for |t| < R, otherwise 1
///
/// where `t` is the signed distance to the cursor in base coordinates and `k = maxScale − 1`.
/// Visual positions are the integral of the density, anchored so that the point under the
/// cursor never moves: `V(u) = x + ∫ₓᵘ m`. Because `V` is monotonic and fixes the cursor,
/// the item drawn under the pointer is always the item whose base slot contains it, which
/// keeps hit targets stable while icons grow.
public nonisolated enum MagnificationCurve {
    /// Antiderivative of the bump part `(1 + cos(π t / R)) / 2`, with `B(0) = 0`.
    public static func bumpIntegral(_ t: Double, radius: Double) -> Double {
        let clamped = min(max(t, -radius), radius)
        return 0.5 * (clamped + (radius / .pi) * sin(.pi * clamped / radius))
    }

    /// Scale factor at signed distance `t` from the cursor.
    public static func density(_ t: Double, k: Double, radius: Double) -> Double {
        guard abs(t) < radius else { return 1 }
        return 1 + k * 0.5 * (1 + cos(.pi * t / radius))
    }
}

/// One horizontal slot of the dock (an icon, a fixed-width widget or a divider).
public nonisolated struct DockSlotSpec: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Magnifying app or folder icon.
        case icon
        /// Non-magnifying element with intrinsic width (Agent Pulse island, widgets).
        case fixed
        /// Thin separator between groups.
        case divider
    }

    public var id: String
    public var kind: Kind
    /// Full slot width in base coordinates, including the spacing around the element.
    public var baseWidth: Double

    public init(id: String, kind: Kind, baseWidth: Double) {
        self.id = id
        self.kind = kind
        self.baseWidth = max(0, baseWidth)
    }
}

public nonisolated struct DockSlotLayout: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: DockSlotSpec.Kind
    public var minX: Double
    public var width: Double
    /// Visual width divided by base width (1 for fixed slots).
    public var scale: Double

    public var midX: Double { minX + width / 2 }
    public var maxX: Double { minX + width }

    public func contains(x: Double) -> Bool { x >= minX && x < maxX }
}

public nonisolated struct DockLayoutResult: Sendable, Equatable {
    public var slots: [DockSlotLayout]
    public var contentMinX: Double
    public var contentMaxX: Double
    public var padding: Double

    public var barMinX: Double { contentMinX - padding }
    public var barMaxX: Double { contentMaxX + padding }
    public var barWidth: Double { barMaxX - barMinX }

    public static let empty = DockLayoutResult(slots: [], contentMinX: 0, contentMaxX: 0, padding: 0)

    public func slot(at x: Double) -> DockSlotLayout? {
        slots.first { $0.contains(x: x) }
    }

    public func slot(id: String) -> DockSlotLayout? {
        slots.first { $0.id == id }
    }
}

/// Pure, deterministic layout of the dock for a given cursor position and magnification
/// amplitude. Everything the dock draws and hit-tests comes from this single function.
public nonisolated enum DockLayoutEngine {
    /// - Parameters:
    ///   - slots: ordered slots.
    ///   - origin: x coordinate where the first slot starts when nothing is magnified.
    ///   - padding: horizontal padding between the bar edge and the first/last slot.
    ///   - cursorX: pointer position in the same coordinate space, or `nil` when not hovering.
    ///   - amplitude: 0...1, the animated strength of the magnification (springs in and out).
    public static func layout(
        slots: [DockSlotSpec],
        origin: Double,
        padding: Double,
        cursorX: Double?,
        amplitude: Double,
        parameters: MagnificationParameters
    ) -> DockLayoutResult {
        guard !slots.isEmpty else {
            return DockLayoutResult(slots: [], contentMinX: origin, contentMaxX: origin, padding: padding)
        }
        let k = (parameters.maxScale - 1) * min(max(amplitude, 0), 1)
        let radius = parameters.radius

        // Base spans.
        var baseStarts: [Double] = []
        baseStarts.reserveCapacity(slots.count)
        var cursor = origin
        for slot in slots {
            baseStarts.append(cursor)
            cursor += slot.baseWidth
        }
        let baseEnd = cursor

        guard k > 0.000_1, let x = cursorX else {
            var result: [DockSlotLayout] = []
            result.reserveCapacity(slots.count)
            for (index, slot) in slots.enumerated() {
                result.append(DockSlotLayout(id: slot.id, kind: slot.kind, minX: baseStarts[index], width: slot.baseWidth, scale: 1))
            }
            return DockLayoutResult(slots: result, contentMinX: origin, contentMaxX: baseEnd, padding: padding)
        }

        // Visual widths.
        var widths: [Double] = []
        widths.reserveCapacity(slots.count)
        for (index, slot) in slots.enumerated() {
            let start = baseStarts[index]
            let end = start + slot.baseWidth
            if slot.kind == .icon, slot.baseWidth > 0 {
                let growth = k * (MagnificationCurve.bumpIntegral(end - x, radius: radius)
                    - MagnificationCurve.bumpIntegral(start - x, radius: radius))
                widths.append(slot.baseWidth + growth)
            } else {
                widths.append(slot.baseWidth)
            }
        }

        // Unanchored visual position of the cursor's base point, V0(x).
        var visualStarts: [Double] = []
        visualStarts.reserveCapacity(slots.count)
        var visualCursor = origin
        for width in widths {
            visualStarts.append(visualCursor)
            visualCursor += width
        }
        let visualEnd = visualCursor

        let anchored: Double
        if x < origin {
            anchored = x
        } else if x >= baseEnd {
            anchored = visualEnd + (x - baseEnd)
        } else {
            let index = indexOfSlot(containing: x, starts: baseStarts)
            let start = baseStarts[index]
            var position = visualStarts[index] + (x - start)
            if slots[index].kind == .icon {
                position -= k * MagnificationCurve.bumpIntegral(start - x, radius: radius)
            }
            anchored = position
        }
        let shift = x - anchored

        var result: [DockSlotLayout] = []
        result.reserveCapacity(slots.count)
        for (index, slot) in slots.enumerated() {
            let scale = slot.baseWidth > 0 ? widths[index] / slot.baseWidth : 1
            result.append(DockSlotLayout(
                id: slot.id,
                kind: slot.kind,
                minX: visualStarts[index] + shift,
                width: widths[index],
                scale: slot.kind == .icon ? scale : 1
            ))
        }
        return DockLayoutResult(
            slots: result,
            contentMinX: origin + shift,
            contentMaxX: visualEnd + shift,
            padding: padding
        )
    }

    /// Upper bound of how much wider the content can become under magnification.
    public static func maximumGrowth(parameters: MagnificationParameters) -> Double {
        (parameters.maxScale - 1) * parameters.radius
    }

    /// Binary search for the last slot whose start is at or before `x`.
    private static func indexOfSlot(containing x: Double, starts: [Double]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= x { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
