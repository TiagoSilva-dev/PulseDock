import AppKit
import Diagnostics
import DockCore
import DockRendering
import Foundation
import Observation

/// The dock's state machine: which entries exist, where everything is this frame, what the
/// pointer is doing. Geometry uses bottom-up coordinates inside the dock window.
@Observable
final class DockModel {
    // MARK: Dependencies

    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let runningApps: RunningApplicationsMonitor
    @ObservationIgnored let accessibility: AccessibilityOptions
    /// Asks the window controller to deliver frames until `tick` reports idle.
    @ObservationIgnored var requestFrames: () -> Void = {}
    /// Called whenever the interactive area changes (the window toggles mouse passthrough).
    @ObservationIgnored var interactiveAreaChanged: () -> Void = {}

    // MARK: Published presentation state

    private(set) var displayEntries: [DockEntry] = []
    private(set) var layout: DockLayoutResult = .empty
    private(set) var presence: [String: Double] = [:]
    private(set) var hoveredEntryID: String?
    private(set) var pressedEntryID: String?
    private(set) var drag: DockDragState?
    private(set) var hiddenFraction: Double = 0
    private(set) var islandWidth: Double = 46
    private(set) var containerSize = CGSize(width: 1200, height: 160)

    /// Whether the Agent Pulse island is part of the bar (workspace filter and settings).
    var showsAgentPulse = true {
        didSet { if showsAgentPulse != oldValue { rebuild() } }
    }

    // MARK: Motion

    @ObservationIgnored private var amplitude = AnimatedValue(0, spring: MotionSprings.magnification, precision: 0.0005)
    @ObservationIgnored private var presenceValues: [String: AnimatedValue] = [:]
    @ObservationIgnored private var islandValue = AnimatedValue(46, spring: MotionSprings.island, precision: 0.1)
    @ObservationIgnored private var hideValue = AnimatedValue(0, spring: MotionSprings.autoHide, precision: 0.0005)
    @ObservationIgnored private var pointer: CGPoint?
    @ObservationIgnored private var lastPointerX: Double?
    @ObservationIgnored private var entries: [DockEntry] = []
    @ObservationIgnored private var leaving: Set<String> = []
    @ObservationIgnored private var hasBuiltOnce = false

    init(settings: SettingsStore, runningApps: RunningApplicationsMonitor, accessibility: AccessibilityOptions) {
        self.settings = settings
        self.runningApps = runningApps
        self.accessibility = accessibility
    }

    // MARK: Derived configuration

    var appearance: AppearanceSettings { settings.settings.appearance }

    var metrics: DockMetrics {
        var metrics = DockMetrics(
            iconSize: appearance.iconSize,
            bottomMargin: settings.settings.behavior.bottomMargin,
            maxMagnification: appearance.magnificationEnabled ? appearance.maxMagnification : 1
        )
        metrics.spacing = (metrics.spacing * appearance.spacing.multiplier).rounded()
        return metrics
    }

    var theme: Theme { Theme.theme(for: settings.settings.effectiveTheme) }

    var isHovering: Bool { amplitude.target > 0 || drag != nil }

    // MARK: Entries

    /// Recomputes entries from the active workspace, running apps and widgets. New entries
    /// grow in, removed ones shrink out.
    func rebuild() {
        let workspace = settings.activeWorkspace
        var result: [DockEntry] = []

        for item in workspace.pinned {
            let url = NSWorkspaceLookup.resolve(item)
            switch item.kind {
            case let .application(bundleIdentifier, path):
                let running = runningApps.runningApp(bundleIdentifier: bundleIdentifier, url: url ?? URL(fileURLWithPath: path))
                let title = running?.name ?? url.map(NSWorkspaceLookup.displayName(for:))
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                result.append(DockEntry(id: item.id.uuidString, kind: .application(pinned: item, running: running),
                                        title: title, url: url ?? running?.bundleURL, isMissing: url == nil && running == nil))
            case let .folder(path):
                result.append(DockEntry(id: item.id.uuidString, kind: .folder(item),
                                        title: FileManager.default.displayName(atPath: path), url: url, isMissing: url == nil))
            }
        }

        if workspace.showRunningApps {
            for app in runningApps.applications where !workspace.pinned.contains(where: { $0.matches(bundleIdentifier: app.bundleIdentifier, url: app.bundleURL) }) {
                let key = app.bundleIdentifier ?? app.bundleURL?.path ?? "pid-\(app.pid)"
                result.append(DockEntry(id: "running:\(key)", kind: .application(pinned: nil, running: app), title: app.name, url: app.bundleURL))
            }
        }

        let widgets = workspace.widgets
        if showsAgentPulse || !widgets.isEmpty {
            result.append(DockEntry(id: "divider:widgets", kind: .divider, title: ""))
        }
        if showsAgentPulse {
            result.append(DockEntry(id: "agentPulse", kind: .agentPulse, title: tr("dock.agentPulse", "Agent Pulse")))
        }
        for placement in widgets {
            result.append(DockEntry(id: "widget:\(placement.id.uuidString)", kind: .widget(placement), title: widgetTitle(placement)))
        }
        if settings.settings.behavior.showTrash {
            result.append(DockEntry(id: "divider:trash", kind: .divider, title: ""))
            result.append(DockEntry(id: "trash", kind: .trash, title: tr("dock.trash", "Trash"), url: AppLauncher.trashURL))
        }

        applyEntries(result)
    }

    private func widgetTitle(_ placement: WidgetPlacement) -> String {
        switch placement.kind {
        case .clock: tr("widget.clock", "Clock")
        case .systemHealth: tr("widget.systemHealth", "System Health")
        case .nowPlaying: tr("widget.nowPlaying", "Now Playing")
        case .quickLaunch:
            settings.settings.collections.first { $0.id == placement.collectionID }?.name ?? tr("widget.quickLaunch", "Quick Launch")
        }
    }

    private func applyEntries(_ newEntries: [DockEntry]) {
        let animate = hasBuiltOnce && appearance.animationsEnabled && !accessibility.reduceMotion
        var target = newEntries
        if let drag, let index = drag.insertionIndex {
            switch drag.source {
            case let .internalEntry(id): target = insertingPlaceholder(into: target, draggedID: id, at: index)
            case .external(true): target = insertingPlaceholder(into: target, draggedID: nil, at: index)
            case .external(false): break
            }
        }
        let targetIDs = Set(target.map(\.id))
        var merged = target
        if animate {
            // Removed entries (and moved drag gaps) stay in place while they shrink out.
            for (index, old) in displayEntries.enumerated() where !targetIDs.contains(old.id) {
                var insertAt = 0
                for previous in displayEntries[..<index].reversed() {
                    if let position = merged.firstIndex(where: { $0.id == previous.id }) {
                        insertAt = position + 1
                        break
                    }
                }
                merged.insert(old, at: min(insertAt, merged.count))
                leaving.insert(old.id)
                presenceValues[old.id, default: AnimatedValue(1, spring: MotionSprings.reorder, precision: 0.002)].target = 0
            }
        } else {
            for old in displayEntries where !targetIDs.contains(old.id) {
                presenceValues.removeValue(forKey: old.id)
                presence.removeValue(forKey: old.id)
            }
        }
        leaving.subtract(targetIDs)
        for entry in target {
            if presenceValues[entry.id] == nil {
                presenceValues[entry.id] = AnimatedValue(animate ? 0 : 1, spring: MotionSprings.reorder, precision: 0.002)
            }
            presenceValues[entry.id]?.spring = accessibility.spring(MotionSprings.reorder)
            presenceValues[entry.id]?.target = isDragHidden(entry.id) ? 0 : 1
            if !animate { presenceValues[entry.id]?.snap() }
        }
        entries = newEntries
        displayEntries = merged
        hasBuiltOnce = true
        recomputeLayout()
        requestFrames()
    }

    private func isDragHidden(_ id: String) -> Bool {
        if let drag, case let .internalEntry(dragged) = drag.source { return dragged == id }
        return false
    }

    private func insertingPlaceholder(into list: [DockEntry], draggedID: String?, at index: Int) -> [DockEntry] {
        var result = list
        let reorderable = result.indices.filter { result[$0].isReorderable && result[$0].id != draggedID }
        let position: Int
        if reorderable.isEmpty {
            position = 0
        } else if index >= reorderable.count {
            position = reorderable[reorderable.count - 1] + 1
        } else {
            position = reorderable[max(0, index)]
        }
        result.insert(DockEntry(id: "placeholder-\(index)", kind: .placeholder, title: ""), at: min(position, result.count))
        return result
    }

    /// Entries that participate in reordering, in display order (excluding placeholders).
    var reorderableEntries: [DockEntry] { entries.filter(\.isReorderable) }

    // MARK: Geometry

    func setContainerSize(_ size: CGSize) {
        guard size != containerSize else { return }
        containerSize = size
        recomputeLayout()
    }

    private func slotSpecs() -> [DockSlotSpec] {
        let metrics = metrics
        return displayEntries.map { entry in
            let factor = presence[entry.id] ?? presenceValues[entry.id]?.value ?? 1
            let width: Double
            switch entry.kind {
            case .divider: width = metrics.dividerSlotWidth
            case .agentPulse: width = islandWidth + metrics.spacing
            case let .widget(placement): width = widgetWidth(placement.kind, metrics: metrics) + metrics.spacing
            default: width = metrics.slotWidth
            }
            return DockSlotSpec(id: entry.id, kind: entry.slotKind, baseWidth: width * factor)
        }
    }

    func widgetWidth(_ kind: WidgetKind, metrics: DockMetrics) -> Double {
        switch kind {
        case .clock: (metrics.iconSize * 1.18).rounded()
        case .systemHealth: (metrics.iconSize * 1.3).rounded()
        case .nowPlaying: (metrics.iconSize * 2.9).rounded()
        case .quickLaunch: metrics.iconSize
        }
    }

    private func recomputeLayout() {
        for (id, value) in presenceValues { presence[id] = value.value }
        let metrics = metrics
        let specs = slotSpecs()
        let total = specs.reduce(0) { $0 + $1.baseWidth }
        let origin = ((containerSize.width - total) / 2).rounded()
        layout = DockLayoutEngine.layout(
            slots: specs,
            origin: origin,
            padding: metrics.horizontalPadding,
            cursorX: lastPointerX,
            amplitude: amplitude.value,
            parameters: metrics.magnificationParameters
        )
    }

    /// Bottom edge of the bar, including the auto-hide offset.
    var barBottom: Double {
        let metrics = metrics
        let hiddenOffset = (metrics.barHeight + metrics.bottomMargin + metrics.shadowInset + 6) * hiddenFraction
        return metrics.bottomMargin - hiddenOffset
    }

    var barRect: CGRect {
        CGRect(x: layout.barMinX, y: barBottom, width: layout.barWidth, height: metrics.barHeight)
    }

    /// Area that must receive mouse events: the bar, plus the magnified icons while hovering
    /// or dragging. Everything else in the window lets clicks through.
    var interactiveRect: CGRect {
        guard hiddenFraction < 0.99 else { return .zero }
        var rect = barRect
        if isHovering || pressedEntryID != nil {
            let top = barBottom + metrics.verticalPadding + metrics.iconSize * metrics.maxMagnification + 6
            rect.size.height = max(rect.height, top - rect.minY)
            if drag != nil { rect.size.height = containerSize.height - rect.minY }
            rect = rect.insetBy(dx: -4, dy: 0)
        }
        return rect
    }

    func entry(at point: CGPoint) -> DockEntry? {
        guard interactiveRect.contains(point), let slot = layout.slot(at: point.x) else { return nil }
        return displayEntries.first { $0.id == slot.id && $0.kind != .divider && $0.kind != .placeholder }
    }

    /// Frame of an entry in container coordinates (bottom-up), for anchoring panels.
    func frame(of entryID: String) -> CGRect? {
        guard let slot = layout.slot(id: entryID) else { return nil }
        let metrics = metrics
        let size = metrics.iconSize * slot.scale
        return CGRect(x: slot.midX - slot.width / 2, y: barBottom + metrics.verticalPadding, width: slot.width, height: size)
    }

    // MARK: Pointer

    func pointerMoved(to point: CGPoint?) {
        pointer = point
        let inside = point.map { interactiveRect.contains($0) || (drag != nil) } ?? false
        if inside, let point {
            lastPointerX = point.x
            let target = appearance.magnificationEnabled ? 1.0 : 0
            amplitude.spring = accessibility.spring(MotionSprings.magnification)
            if amplitude.target != target { amplitude.target = target }
        } else if amplitude.target != 0 {
            amplitude.target = 0
        }
        let hovered = point.flatMap { entry(at: $0) }?.id
        if hovered != hoveredEntryID { hoveredEntryID = hovered }
        recomputeLayout()
        requestFrames()
        interactiveAreaChanged()
    }

    func setPressed(_ id: String?) {
        pressedEntryID = id
    }

    // MARK: Auto-hide and island

    func setHidden(_ hidden: Bool, animated: Bool) {
        hideValue.spring = accessibility.spring(MotionSprings.autoHide)
        hideValue.target = hidden ? 1 : 0
        if !animated || !appearance.animationsEnabled { hideValue.snap() }
        hiddenFraction = hideValue.value
        requestFrames()
        interactiveAreaChanged()
    }

    var isHiddenTarget: Bool { hideValue.target > 0.5 }

    func setIslandWidth(_ width: Double) {
        let rounded = width.rounded()
        guard abs(islandValue.target - rounded) > 0.5 else { return }
        islandValue.spring = accessibility.spring(MotionSprings.island)
        islandValue.target = rounded
        if !appearance.animationsEnabled { islandValue.snap() }
        requestFrames()
    }

    // MARK: Drag state

    func updateDrag(_ state: DockDragState?) {
        let previousIndex = drag?.insertionIndex
        let previousSource = drag?.source
        drag = state
        if state?.insertionIndex != previousIndex || state?.source != previousSource {
            applyEntries(entries)
        } else {
            recomputeLayout()
        }
        interactiveAreaChanged()
    }

    /// Index among reorderable entries where a drop at `x` would land.
    func insertionIndex(forX x: Double, excluding draggedID: String?) -> Int {
        let candidates = reorderableEntries.filter { $0.id != draggedID }
        var index = 0
        for candidate in candidates {
            guard let slot = layout.slot(id: candidate.id) else { continue }
            if x > slot.midX { index += 1 }
        }
        return index
    }

    // MARK: Frame loop

    /// Steps every animated value; returns whether more frames are needed.
    func tick(_ deltaTime: Double) -> Bool {
        var active = false
        if !amplitude.isSettled {
            amplitude.step(deltaTime)
            active = true
        }
        if !hideValue.isSettled {
            hideValue.step(deltaTime)
            hiddenFraction = hideValue.value
            active = true
        } else if hiddenFraction != hideValue.value {
            hiddenFraction = hideValue.value
        }
        if !islandValue.isSettled {
            islandValue.step(deltaTime)
            active = true
        }
        if islandWidth != islandValue.value { islandWidth = islandValue.value }
        var finishedLeaving: [String] = []
        for id in Array(presenceValues.keys) {
            guard var value = presenceValues[id], !value.isSettled else { continue }
            value.step(deltaTime)
            presenceValues[id] = value
            active = true
            if value.isSettled, value.target == 0, leaving.contains(id) { finishedLeaving.append(id) }
        }
        if !finishedLeaving.isEmpty {
            for id in finishedLeaving {
                leaving.remove(id)
                presenceValues.removeValue(forKey: id)
                presence.removeValue(forKey: id)
            }
            displayEntries.removeAll { finishedLeaving.contains($0.id) }
        }
        // Drop presence values of entries that no longer exist at all.
        let known = Set(displayEntries.map(\.id))
        for id in presenceValues.keys where !known.contains(id) { presenceValues.removeValue(forKey: id) }

        recomputeLayout()
        if !active { interactiveAreaChanged() }
        return active
    }
}
