import Foundation

/// Spring described the way SwiftUI does: `response` is the period of the undamped
/// oscillation (seconds) and `dampingFraction` is 1 for critical damping.
public nonisolated struct SpringSpec: Sendable, Equatable {
    public var response: Double
    public var dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = max(0.01, response)
        self.dampingFraction = max(0, dampingFraction)
    }

    public var stiffness: Double { pow(2 * .pi / response, 2) }
    public var damping: Double { 4 * .pi * dampingFraction / response }
}

/// A scalar driven by a damped harmonic oscillator. Used for values the dock animates
/// itself (pointer tracking, magnification amplitude, island width, auto-hide offset),
/// where the current presented value must be known exactly for hit-testing.
public nonisolated struct AnimatedValue: Sendable, Equatable {
    public var value: Double
    public var velocity: Double
    public var target: Double
    public var spring: SpringSpec
    /// Distance below which the value is considered at rest (in the value's own units).
    public var precision: Double

    public init(_ value: Double, spring: SpringSpec, precision: Double = 0.01) {
        self.value = value
        self.velocity = 0
        self.target = value
        self.spring = spring
        self.precision = precision
    }

    public var isSettled: Bool {
        abs(value - target) <= precision && abs(velocity) <= precision * 10
    }

    /// Integrates the spring with fixed sub-steps (semi-implicit Euler, stable for the
    /// stiffness range we use). Large gaps (e.g. after the app was suspended) are clamped.
    public mutating func step(_ deltaTime: Double) {
        guard !isSettled else {
            value = target
            velocity = 0
            return
        }
        var remaining = min(max(deltaTime, 0), 0.1)
        let stiffness = spring.stiffness
        let damping = spring.damping
        while remaining > 0 {
            let h = min(remaining, 1.0 / 480.0)
            let force = -stiffness * (value - target) - damping * velocity
            velocity += force * h
            value += velocity * h
            remaining -= h
        }
        if isSettled {
            value = target
            velocity = 0
        }
    }

    public mutating func snap(to newValue: Double? = nil) {
        if let newValue { target = newValue }
        value = target
        velocity = 0
    }
}
