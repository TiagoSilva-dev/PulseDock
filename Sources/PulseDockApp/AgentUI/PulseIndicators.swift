import AppKit
import DockRendering
import SwiftUI

/// "Working" indicator: three bars rising and falling. Animated with Core Animation, so the
/// motion is rendered by the window server and costs the app no CPU per frame. Static when
/// Reduce Motion (or Animations off) is set.
struct PulseWaveIndicator: NSViewRepresentable {
    var color: NSColor
    var animated: Bool

    func makeNSView(context: Context) -> WaveView { WaveView() }

    func updateNSView(_ view: WaveView, context: Context) {
        view.configure(color: color, animated: animated)
    }

    final class WaveView: NSView {
        private var bars: [CALayer] = []
        private var currentColor: NSColor?
        private var isAnimating = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for _ in 0..<3 {
                let bar = CALayer()
                bar.cornerRadius = 1.25
                layer?.addSublayer(bar)
                bars.append(bar)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            let width: CGFloat = 2.5
            let gap: CGFloat = 2.5
            let total = width * 3 + gap * 2
            let startX = (bounds.width - total) / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, bar) in bars.enumerated() {
                bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height * 0.9)
                bar.position = CGPoint(x: startX + width / 2 + CGFloat(index) * (width + gap), y: bounds.midY)
            }
            CATransaction.commit()
        }

        func configure(color: NSColor, animated: Bool) {
            if currentColor != color {
                currentColor = color
                bars.forEach { $0.backgroundColor = color.cgColor }
            }
            guard animated != isAnimating else { return }
            isAnimating = animated
            for (index, bar) in bars.enumerated() {
                bar.removeAllAnimations()
                if animated {
                    let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
                    animation.values = [0.35, 1.0, 0.45, 0.8, 0.35]
                    animation.keyTimes = [0, 0.3, 0.55, 0.8, 1]
                    animation.duration = 1.6
                    animation.timeOffset = Double(index) * 0.27
                    animation.repeatCount = .infinity
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    bar.add(animation, forKey: "wave")
                } else {
                    bar.transform = CATransform3DMakeScale(1, [0.55, 0.9, 0.65][index], 1)
                }
            }
        }
    }
}

/// Localised ambient light behind the Agent Pulse island. Never covers the whole dock; it
/// breathes slowly (1.5–2.5 s) only while something relevant happens.
struct AmbientGlow: NSViewRepresentable {
    var color: NSColor
    var intensity: Double
    var breathing: Bool
    var cornerRadius: Double

    func makeNSView(context: Context) -> GlowView { GlowView() }

    func updateNSView(_ view: GlowView, context: Context) {
        view.configure(color: color, intensity: intensity, breathing: breathing, cornerRadius: cornerRadius)
    }

    final class GlowView: NSView {
        private let glow = CALayer()
        private var state: (NSColor, Double, Bool)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            glow.shadowOffset = .zero
            glow.shadowRadius = 13
            glow.shadowOpacity = 0
            layer?.addSublayer(glow)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var radius: Double = 17

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.frame = bounds
            glow.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), cornerWidth: radius, cornerHeight: radius, transform: nil)
            CATransaction.commit()
        }

        func configure(color: NSColor, intensity: Double, breathing: Bool, cornerRadius: Double) {
            radius = min(cornerRadius, bounds.height / 2)
            if let state, state.0 == color, state.1 == intensity, state.2 == breathing { return }
            state = (color, intensity, breathing)
            glow.shadowColor = color.cgColor
            glow.removeAnimation(forKey: "breathe")
            let target = Float(max(0, min(1, intensity)))
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.45)
            glow.shadowOpacity = breathing ? target * 0.55 : target
            CATransaction.commit()
            guard breathing, target > 0 else { return }
            let animation = CABasicAnimation(keyPath: "shadowOpacity")
            animation.fromValue = target * 0.35
            animation.toValue = target
            animation.duration = 1.9
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(animation, forKey: "breathe")
        }
    }
}

/// Marks simulated data wherever it appears, so demo sessions are never mistaken for real ones.
struct DemoBadge: View {
    var body: some View {
        Text(tr("demo.badge", "DEMO"))
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.purple.opacity(0.8)))
            .fixedSize()
            .accessibilityLabel(tr("demo.badge.accessibility", "Demo data"))
    }
}
