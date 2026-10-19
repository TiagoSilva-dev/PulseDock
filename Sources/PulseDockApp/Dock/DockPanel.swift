import AppKit

/// Borderless, non-activating, transparent panel that hosts the dock. It never becomes key
/// or main, so clicking the dock never steals focus from the frontmost app.
final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        // All Spaces, not part of window cycling. Without `.fullScreenAuxiliary` the dock does
        // not appear inside full-screen Spaces.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        title = "PulseDock"
        setAccessibilityLabel("PulseDock")
        setAccessibilityRole(.toolbar)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
