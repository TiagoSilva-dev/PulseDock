import AppKit
import Diagnostics
import DockCore
import DockRendering
import SwiftUI

/// Places the dock panel on the chosen display, keeps mouse passthrough in sync with the
/// interactive area, drives auto-hide and reacts to display and Space changes.
final class DockWindowController {
    let panel = DockPanel()
    let model: DockModel
    let host: DockHostView
    private let settings: SettingsStore
    private lazy var frameDriver = FrameDriver { [weak self] delta in self?.model.tick(delta) ?? false }
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var revealTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var lastPointerScreen: NSScreen?
    private(set) var currentScreen: NSScreen?
    /// Set while a menu or panel anchored to the dock is open, so auto-hide waits.
    var isPresentingAuxiliaryUI = false {
        didSet { if !isPresentingAuxiliaryUI { evaluateAutoHide(pointer: currentPointer()) } }
    }
    private var suppressedByFullScreenApp = false

    init(model: DockModel, settings: SettingsStore, content: some View) {
        self.model = model
        self.settings = settings
        host = DockHostView(model: model, content: content)
        panel.contentView = host
        model.requestFrames = { [weak self] in self?.frameDriver.wake() }
        model.interactiveAreaChanged = { [weak self] in self?.updatePassthrough() }
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        frameDriver.attach(to: host)
        installMonitors()
        model.rebuild()
        applyAutoHideSetting()
        checkFullScreenSuppression()
    }

    func tearDown() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        frameDriver.invalidate()
        panel.orderOut(nil)
    }

    // MARK: Placement

    /// Height of the dock window: bar, magnification headroom, labels and drag-out room.
    private var windowHeight: Double {
        let metrics = model.metrics
        return metrics.bottomMargin + metrics.barHeight + metrics.headroom + metrics.shadowInset + 40
    }

    func reposition() {
        let preference = settings.settings.behavior.display
        guard let screen = DisplayLocator.resolve(preference, lastPointerScreen: lastPointerScreen) else { return }
        currentScreen = screen
        // `visibleFrame` excludes the macOS Dock when it is visible at the bottom, so in
        // Companion Mode PulseDock sits above it instead of covering it.
        let baseY = screen.visibleFrame.minY
        let frame = CGRect(x: screen.frame.minX, y: baseY, width: screen.frame.width, height: windowHeight).integral
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        host.frame = CGRect(origin: .zero, size: frame.size)
        model.setContainerSize(frame.size)
        updatePassthrough()
    }

    // MARK: Pointer tracking and passthrough

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.globalPointerMoved() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.globalPointerMoved() }
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reposition()
                self?.checkFullScreenSuppression()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkFullScreenSuppression() }
            })
        }
    }

    private func currentPointer() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
    }

    private func globalPointerMoved() {
        let mouse = NSEvent.mouseLocation
        if settings.settings.behavior.display == .followPointer {
            followPointer(mouse)
        }
        let point = currentPointer()
        let nearDock = panel.frame.insetBy(dx: 0, dy: -2).contains(mouse)
        if nearDock || model.hoveredEntryID != nil || model.isHovering {
            host.pointerChanged(model.interactiveRect.contains(point) ? point : nil)
        }
        updatePassthrough()
        evaluateAutoHide(pointer: point)
    }

    func updatePassthrough() {
        let inside = model.interactiveRect.contains(currentPointer()) || model.drag != nil
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
    }

    /// With "follow pointer", the dock moves to a display when the pointer pushes against
    /// that display's bottom edge, like the macOS Dock.
    private func followPointer(_ mouse: CGPoint) {
        guard let screen = DisplayLocator.screenContaining(point: mouse), screen != currentScreen,
              mouse.y <= screen.frame.minY + 1 else { return }
        lastPointerScreen = screen
        reposition()
    }

    // MARK: Auto-hide

    func applyAutoHideSetting() {
        if settings.settings.behavior.autoHide || suppressedByFullScreenApp {
            if !model.isHovering { model.setHidden(true, animated: true) }
        } else {
            revealTask?.cancel()
            hideTask?.cancel()
            model.setHidden(false, animated: true)
        }
    }

    private func evaluateAutoHide(pointer: CGPoint) {
        let behavior = settings.settings.behavior
        guard behavior.autoHide, !suppressedByFullScreenApp else { return }
        if model.isHiddenTarget {
            // Reveal zone: the bottom edge of the dock's area on this display.
            let bar = model.barRect
            let zone = CGRect(x: bar.minX - 40, y: -2, width: bar.width + 80, height: 6)
            if zone.contains(pointer) {
                guard revealTask == nil else { return }
                revealTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(behavior.revealDelay))
                    guard let self, !Task.isCancelled else { return }
                    self.revealTask = nil
                    if behavior.avoidFullScreenApps, let screen = self.currentScreen, DisplayLocator.frontmostAppCoversScreen(screen) { return }
                    self.hideTask?.cancel()
                    self.model.setHidden(false, animated: true)
                }
            } else {
                revealTask?.cancel()
                revealTask = nil
            }
        } else {
            let keepVisible = model.interactiveRect.insetBy(dx: -24, dy: -24).contains(pointer)
                || isPresentingAuxiliaryUI || model.drag != nil || model.pressedEntryID != nil
            if keepVisible {
                hideTask?.cancel()
                hideTask = nil
            } else if hideTask == nil {
                hideTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(behavior.hideDelay))
                    guard let self, !Task.isCancelled else { return }
                    self.hideTask = nil
                    self.model.setHidden(true, animated: true)
                }
            }
        }
    }

    /// Hides the dock while the frontmost app covers the whole display (borderless
    /// full-screen games and players), when the user asked for it.
    private func checkFullScreenSuppression() {
        guard let screen = currentScreen else { return }
        let suppress = settings.settings.behavior.avoidFullScreenApps && DisplayLocator.frontmostAppCoversScreen(screen)
        guard suppress != suppressedByFullScreenApp else { return }
        suppressedByFullScreenApp = suppress
        PulseLog.dock.info("Full-screen suppression: \(suppress, privacy: .public)")
        applyAutoHideSetting()
    }

    /// Anchor for panels shown above an entry, in screen coordinates.
    func screenFrame(ofEntry id: String) -> CGRect? {
        guard let frame = model.frame(of: id) else { return nil }
        return frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    var barScreenFrame: CGRect {
        model.barRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }
}
