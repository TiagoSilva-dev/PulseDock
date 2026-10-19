@testable import DockRendering
import Foundation
import Testing

@Suite("Magnification layout invariants")
struct MagnificationTests {
    let metrics = DockMetrics(iconSize: 54)

    func slots(_ count: Int) -> [DockSlotSpec] {
        var result = (0..<count).map { DockSlotSpec(id: "i\($0)", kind: .icon, baseWidth: metrics.slotWidth) }
        result.insert(DockSlotSpec(id: "divider", kind: .divider, baseWidth: metrics.dividerSlotWidth), at: count / 2)
        result.append(DockSlotSpec(id: "island", kind: .fixed, baseWidth: 160))
        return result
    }

    func layout(_ slots: [DockSlotSpec], cursor: Double?, amplitude: Double = 1) -> DockLayoutResult {
        DockLayoutEngine.layout(slots: slots, origin: 100, padding: metrics.horizontalPadding, cursorX: cursor,
                                amplitude: amplitude, parameters: metrics.magnificationParameters)
    }

    @Test("No magnification without hover or amplitude")
    func restingLayout() {
        let base = slots(10)
        let rest = layout(base, cursor: nil)
        #expect(rest.slots.allSatisfy { $0.scale == 1 })
        #expect(layout(base, cursor: 300, amplitude: 0) == rest)
        #expect(rest.contentMaxX - rest.contentMinX == base.reduce(0) { $0 + $1.baseWidth })
    }

    @Test("The item under the pointer stays under the pointer (stable hit target)")
    func anchoredUnderCursor() {
        let base = slots(12)
        let rest = layout(base, cursor: nil)
        var x = rest.contentMinX + 1
        while x < rest.contentMaxX - 1 {
            let baseHit = rest.slot(at: x)
            for amplitude in [0.25, 0.5, 1.0] {
                let magnified = layout(base, cursor: x, amplitude: amplitude)
                #expect(magnified.slot(at: x)?.id == baseHit?.id, "x=\(x) amplitude=\(amplitude)")
            }
            x += 7.3
        }
    }

    @Test("Slots never overlap and stay in order")
    func monotonic() {
        let base = slots(14)
        for cursor in stride(from: 50.0, through: 1200, by: 37) {
            let result = layout(base, cursor: cursor)
            for (left, right) in zip(result.slots, result.slots.dropFirst()) {
                #expect(abs(left.maxX - right.minX) < 0.0001)
            }
        }
    }

    @Test("Peak scale matches the configured maximum; growth is bounded")
    func peakAndBounds() {
        let base = slots(12)
        let rest = layout(base, cursor: nil)
        let center = rest.slots[3].midX
        let result = layout(base, cursor: center)
        let peak = result.slots.map(\.scale).max() ?? 1
        #expect(peak > metrics.maxMagnification - 0.02)
        #expect(peak <= metrics.maxMagnification + 0.0001)
        let growth = (result.contentMaxX - result.contentMinX) - (rest.contentMaxX - rest.contentMinX)
        #expect(growth <= DockLayoutEngine.maximumGrowth(parameters: metrics.magnificationParameters) + 0.001)
        #expect(result.slots.filter { $0.kind != .icon }.allSatisfy { $0.scale == 1 })
    }

    @Test("Neighbours grow less with distance")
    func falloff() {
        let base = slots(12)
        let rest = layout(base, cursor: nil)
        let result = layout(base, cursor: rest.slots[1].midX)
        let icons = result.slots.filter { $0.kind == .icon }
        #expect(icons[1].scale > icons[2].scale)
        #expect(icons[2].scale > icons[3].scale)
        #expect(icons[8].scale == 1)
    }

    @Test("Springs settle on target and respect precision")
    func springSettles() {
        var value = AnimatedValue(0, spring: MotionSprings.magnification, precision: 0.001)
        value.target = 1
        var steps = 0
        while !value.isSettled && steps < 600 {
            value.step(1.0 / 120)
            steps += 1
        }
        #expect(value.isSettled)
        #expect(value.value == 1)
        #expect(steps < 120)
    }
}
