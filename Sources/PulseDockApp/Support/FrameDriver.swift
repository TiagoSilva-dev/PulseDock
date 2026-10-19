import AppKit
import QuartzCore

/// Calls `tick` once per display frame while `isActive`, using the display link of the view's
/// screen (macOS 14+). The link is paused whenever nothing animates, so an idle dock costs no
/// CPU at all.
final class FrameDriver: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let tick: (Double) -> Bool

    /// `tick` receives the elapsed time in seconds and returns `true` while more frames are needed.
    init(tick: @escaping (Double) -> Bool) {
        self.tick = tick
    }

    func attach(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    /// Starts delivering frames (no-op if already running).
    func wake() {
        guard let link, link.isPaused else { return }
        lastTimestamp = nil
        link.isPaused = false
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let delta = lastTimestamp.map { now - $0 } ?? (1.0 / 120)
        lastTimestamp = now
        if !tick(min(max(delta, 0), 1.0 / 20)) {
            link.isPaused = true
            lastTimestamp = nil
        }
    }
}
