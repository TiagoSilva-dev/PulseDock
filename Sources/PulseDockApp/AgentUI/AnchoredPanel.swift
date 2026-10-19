import AppKit
import SwiftUI

/// Floating panel anchored above an element of the dock (Agent Card, Quick Peek, widget
/// panels). It can take keyboard focus for navigation without activating PulseDock, and it
/// closes on Escape, on an outside click or when the anchor goes away.
final class AnchoredPanel: NSPanel {
    var allowsKey: Bool
    var onClose: () -> Void = {}
    private var outsideClickMonitor: Any?
    private var localKeyMonitor: Any?

    init(allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = !allowsKey
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Shows `content` above `anchor` (screen coordinates), centred horizontally and kept
    /// inside the visible frame of the anchor's screen.
    func present<Content: View>(_ content: Content, size: CGSize, above anchor: CGRect, gap: Double = 10) {
        let hosting = OpaqueColorHostingView(rootView: content)
        hosting.sizingOptions = []
        contentView = hosting
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(origin.y, bounds.maxY - size.height - 8)
        setFrame(CGRect(origin: origin, size: size).integral, display: true)
        orderFrontRegardless()
        if allowsKey { makeKey() }
        installMonitors()
    }

    func resize(to size: CGSize, above anchor: CGRect, gap: Double = 10) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? frame
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(origin.y, bounds.maxY - size.height - 8)
        setFrame(CGRect(origin: origin, size: size).integral, display: true, animate: false)
    }

    func dismiss() {
        removeMonitors()
        orderOut(nil)
        contentView = nil
        onClose()
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                MainActor.assumeIsolated { self?.dismiss() }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        outsideClickMonitor = nil
        localKeyMonitor = nil
    }

    override func resignKey() {
        super.resignKey()
        if allowsKey { dismiss() }
    }
}

/// Hosting view that opts out of AppKit vibrancy, so coloured content (state chips, amber
/// attention lines) keeps the exact theme colours over the material — vibrancy is meant for
/// monochrome labels. Legibility on these panels comes from the adaptive scrim of
/// `PulseGlassSurface` and from per-appearance theme tones.
final class OpaqueColorHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool { false }
}
