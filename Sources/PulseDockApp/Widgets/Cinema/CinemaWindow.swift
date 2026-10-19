import AppKit
import DockRendering
import SwiftUI
import WebKit

/// The floating player: a borderless, resizable 16:9 panel that follows the user across
/// Spaces and full-screen apps (like picture in picture), with glass controls that appear
/// on hover. It never takes focus from the app the user is working in.
final class CinemaWindow: NSPanel {
    var onFrameChange: (CGRect) -> Void = { _ in }
    private weak var controller: CinemaController?
    private let hover = CinemaHoverState()
    private let container: CinemaContainerView
    private let overlay: CinemaOverlayHostingView
    private var frameObservers: [NSObjectProtocol] = []

    init(frame: CGRect, controller: CinemaController) {
        self.controller = controller
        container = CinemaContainerView(hover: hover)
        overlay = CinemaOverlayHostingView(rootView: CinemaOverlay(controller: controller, hover: hover))
        overlay.hover = hover
        overlay.controller = controller
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentAspectRatio = CGSize(width: 16, height: 9)
        contentMinSize = CGSize(width: 288, height: 162)
        animationBehavior = .utilityWindow
        title = tr("widget.cinema", "Dock Cinema")

        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        contentView = container
        overlay.translatesAutoresizingMaskIntoConstraints = true
        overlay.autoresizingMask = [.width, .height]
        overlay.frame = container.bounds
        overlay.sizingOptions = []
        container.addSubview(overlay)

        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onFrameChange(self.frame)
                }
            })
        }
    }

    isolated deinit {
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The web view goes under the SwiftUI overlay (controls, agent banner).
    func install(webView: WKWebView) {
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView, positioned: .below, relativeTo: overlay)
    }
}

/// Hover controls drawn over the video. The middle stays transparent to clicks so YouTube's
/// own controls keep working; the top strip is a drag handle.
struct CinemaOverlay: View {
    let controller: CinemaController
    let hover: CinemaHoverState

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .opacity(hover.isHovering || controller.pausedForAgent != nil ? 1 : 0)
            Spacer(minLength: 0)
                .allowsHitTesting(false)
            if let reason = controller.pausedForAgent {
                agentBanner(reason)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: hover.isHovering)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: controller.pausedForAgent)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(controller.current?.title ?? tr("widget.cinema", "Dock Cinema"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            button("arrow.up.right.square", tr("cinema.openYouTube", "Open on YouTube")) { controller.openOnYouTube() }
            if !controller.queue.isEmpty {
                button("forward.end.fill", tr("cinema.next", "Next video")) { controller.playNext() }
            }
            button("xmark", tr("cinema.close", "Close player")) { controller.stop() }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0)], startPoint: .top, endPoint: .bottom))
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func agentBanner(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("cinema.pausedForAgent", "Paused — an agent needs you"))
                    .font(.system(size: 11.5, weight: .semibold))
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(tr("cinema.resume", "Resume")) { controller.togglePlayback() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

@Observable
final class CinemaHoverState {
    var isHovering = false
}

/// Tracks the pointer over the whole player, whichever subview (web view or overlay) gets
/// the events.
final class CinemaContainerView: NSView {
    private let hover: CinemaHoverState

    init(hover: CinemaHoverState) {
        self.hover = hover
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseEntered(with event: NSEvent) { hover.isHovering = true }
    override func mouseExited(with event: NSEvent) { hover.isHovering = false }
}

/// The overlay only takes clicks on its visible controls: the top strip while it is shown and
/// the agent banner. Everything else reaches YouTube's player underneath.
final class CinemaOverlayHostingView: NSHostingView<CinemaOverlay> {
    weak var hover: CinemaHoverState?
    weak var controller: CinemaController?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let fromTop = isFlipped ? local.y : bounds.height - local.y
        let fromBottom = bounds.height - fromTop
        if fromTop <= 30, hover?.isHovering == true || controller?.pausedForAgent != nil {
            return super.hitTest(point)
        }
        if controller?.pausedForAgent != nil, fromBottom <= 64 {
            return super.hitTest(point)
        }
        return nil
    }
}
