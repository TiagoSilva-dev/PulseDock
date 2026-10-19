import AppKit
import DockCore
import SwiftUI

/// What the dock asks the rest of the app to do.
@MainActor
protocol DockInteractionDelegate: AnyObject {
    func dockActivate(_ entry: DockEntry, modifiers: NSEvent.ModifierFlags)
    func dockShowMenu(for entry: DockEntry?, event: NSEvent, in view: NSView)
    func dockCommitReorder(entryID: String, toIndex: Int)
    func dockRemove(entryID: String)
    func dockDrop(urls: [URL], onto entry: DockEntry?, insertionIndex: Int?) -> Bool
    func dockWidgetAcceptsDrop(_ placement: WidgetPlacement, pasteboard: NSPasteboard) -> Bool
    func dockWidgetDrop(_ placement: WidgetPlacement, pasteboard: NSPasteboard) -> Bool
    func dockHoverChanged(_ entry: DockEntry?)
}

/// AppKit layer of the dock: receives every mouse and drag event, hit-tests against the
/// model's layout (the same geometry that is drawn) and forwards intents to the delegate.
/// SwiftUI only renders; it never receives events, so hit targets cannot drift from the
/// visuals.
final class DockHostView: NSView {
    let model: DockModel
    weak var delegate: DockInteractionDelegate?
    private let hosting: NSView
    private var trackingArea: NSTrackingArea?
    private var mouseDownEntry: DockEntry?
    private var mouseDownPoint: CGPoint = .zero
    private var isDraggingEntry = false
    private var dragShowsPoof = false

    private static let dragThreshold: Double = 4
    private static let removeDistance: Double = 52

    init(model: DockModel, content: some View) {
        self.model = model
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        self.hosting = hosting
        super.init(frame: .zero)
        wantsLayer = true
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        registerForDraggedTypes([.fileURL, .URL, .string])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        model.setContainerSize(bounds.size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: Hover

    override func mouseMoved(with event: NSEvent) {
        pointerChanged(location(of: event))
    }

    override func mouseEntered(with event: NSEvent) {
        pointerChanged(location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDraggingEntry else { return }
        pointerChanged(nil)
    }

    func pointerChanged(_ point: CGPoint?) {
        let before = model.hoveredEntryID
        model.pointerMoved(to: point)
        if model.hoveredEntryID != before {
            delegate?.dockHoverChanged(model.displayEntries.first { $0.id == model.hoveredEntryID })
        }
    }

    // MARK: Clicks and internal drags

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        mouseDownPoint = point
        mouseDownEntry = model.entry(at: point)
        isDraggingEntry = false
        model.setPressed(mouseDownEntry?.id)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = location(of: event)
        guard let entry = mouseDownEntry else { return }
        if !isDraggingEntry {
            guard entry.isReorderable, hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > DockHostView.dragThreshold else { return }
            isDraggingEntry = true
            model.setPressed(nil)
        }
        let removable = entry.pinned != nil
        let removeIntent = removable && point.y > model.barRect.maxY + DockHostView.removeDistance
        if removeIntent != dragShowsPoof {
            dragShowsPoof = removeIntent
            (removeIntent ? NSCursor.disappearingItem : NSCursor.arrow).set()
        }
        let index = removeIntent ? nil : model.insertionIndex(forX: point.x, excluding: entry.id)
        model.updateDrag(DockDragState(source: .internalEntry(entry.id), location: point, insertionIndex: index, removeIntent: removeIntent))
        pointerChanged(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = location(of: event)
        defer {
            mouseDownEntry = nil
            isDraggingEntry = false
            model.setPressed(nil)
        }
        if isDraggingEntry, let entry = mouseDownEntry {
            let state = model.drag
            model.updateDrag(nil)
            if dragShowsPoof {
                dragShowsPoof = false
                NSCursor.arrow.set()
                if state?.removeIntent == true {
                    delegate?.dockRemove(entryID: entry.id)
                }
            } else if let index = state?.insertionIndex {
                delegate?.dockCommitReorder(entryID: entry.id, toIndex: index)
            }
            pointerChanged(point)
            return
        }
        guard let entry = mouseDownEntry, model.entry(at: point)?.id == entry.id else { return }
        delegate?.dockActivate(entry, modifiers: event.modifierFlags)
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.dockShowMenu(for: model.entry(at: location(of: event)), event: event, in: self)
    }

    override func otherMouseDown(with event: NSEvent) {
        rightMouseDown(with: event)
    }

    // MARK: External drops (files and apps from Finder)

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// A widget under the pointer that takes this drop (AirDrop, Shelf, Dock Cinema, Note).
    private func widgetTarget(_ info: NSDraggingInfo, at point: CGPoint) -> (DockEntry, WidgetPlacement)? {
        guard let entry = model.entry(at: point), case let .widget(placement) = entry.kind, placement.kind.acceptsDrops,
              delegate?.dockWidgetAcceptsDrop(placement, pasteboard: info.draggingPasteboard) == true else { return nil }
        return (entry, placement)
    }

    private func evaluate(_ info: NSDraggingInfo) -> NSDragOperation {
        let point = convert(info.draggingLocation, from: nil)
        if let (entry, _) = widgetTarget(info, at: point) {
            pointerChanged(point)
            model.updateDrag(DockDragState(source: .external(acceptsPinning: false), location: point, insertionIndex: nil, targetEntryID: entry.id))
            return .copy
        }
        let urls = fileURLs(info)
        guard !urls.isEmpty else { return [] }
        pointerChanged(point)
        let pinnable = urls.allSatisfy { url in
            url.pathExtension == "app" || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let target = model.entry(at: point)
        switch target?.kind {
        case .trash:
            model.updateDrag(DockDragState(source: .external(acceptsPinning: false), location: point, insertionIndex: nil, targetEntryID: target?.id))
            return .delete
        case .application where !pinnable:
            model.updateDrag(DockDragState(source: .external(acceptsPinning: false), location: point, insertionIndex: nil, targetEntryID: target?.id))
            return .copy
        default:
            guard pinnable else {
                model.updateDrag(DockDragState(source: .external(acceptsPinning: false), location: point))
                return []
            }
            let index = min(model.insertionIndex(forX: point.x, excluding: nil), settingsPinnedCount)
            model.updateDrag(DockDragState(source: .external(acceptsPinning: true), location: point, insertionIndex: index))
            return .link
        }
    }

    private var settingsPinnedCount: Int { model.settings.activeWorkspace.pinned.count }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { evaluate(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { evaluate(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model.updateDrag(nil)
        pointerChanged(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        if let (_, placement) = widgetTarget(sender, at: point) {
            model.updateDrag(nil)
            return delegate?.dockWidgetDrop(placement, pasteboard: sender.draggingPasteboard) ?? false
        }
        let state = model.drag
        let urls = fileURLs(sender)
        let target = state?.targetEntryID.flatMap { id in model.displayEntries.first { $0.id == id } }
        model.updateDrag(nil)
        return delegate?.dockDrop(urls: urls, onto: target, insertionIndex: state?.insertionIndex) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        pointerChanged(sender.map { convert($0.draggingLocation, from: nil) })
    }
}
