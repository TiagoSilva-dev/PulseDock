import AppKit
import DockCore
import DockRendering
import SwiftUI

/// Views the dock embeds but does not own (Agent Pulse island, widgets) and actions exposed
/// to accessibility clients.
@MainActor
final class DockAccessories {
    var island: () -> AnyView = { AnyView(EmptyView()) }
    var widget: (WidgetPlacement, CGSize) -> AnyView = { _, _ in AnyView(EmptyView()) }
    var activate: (DockEntry) -> Void = { _ in }
    var trashIsFull: () -> Bool = { false }
}

/// Renders the dock from `DockModel` state. Purely visual: positions come from the layout
/// engine and nothing here handles events.
struct DockRootView: View {
    let model: DockModel
    let accessories: DockAccessories
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let theme = model.theme
        content(theme: theme)
            .environment(\.colorScheme, theme.forcedColorScheme ?? systemScheme)
    }

    private func content(theme: Theme) -> some View {
        let metrics = model.metrics
        let height = model.containerSize.height
        let layout = model.layout
        let barBottom = model.barBottom
        let appearance = model.appearance
        return ZStack(alignment: .topLeading) {
            if layout.barWidth > 1, model.hiddenFraction < 0.999 {
                PulseGlassSurface(
                    theme: theme,
                    cornerRadius: metrics.cornerRadius,
                    accessibility: model.accessibility,
                    opacity: appearance.transparency.surfaceOpacity,
                    borderEmphasis: appearance.border.emphasis
                )
                .frame(width: layout.barWidth, height: metrics.barHeight)
                .position(x: layout.barMinX + layout.barWidth / 2, y: height - barBottom - metrics.barHeight / 2)
                .accessibilityHidden(true)
            }

            ForEach(model.displayEntries) { entry in
                if let slot = layout.slot(id: entry.id) {
                    DockEntryView(
                        entry: entry,
                        slot: slot,
                        metrics: metrics,
                        theme: theme,
                        containerHeight: height,
                        barBottom: barBottom,
                        presence: model.presence[entry.id] ?? 1,
                        isPressed: model.pressedEntryID == entry.id,
                        isDropTarget: model.drag?.targetEntryID == entry.id,
                        isLaunching: entry.url.map { model.runningApps.launchingPaths.contains($0.path) } ?? false,
                        isFrontmost: entry.running.map { $0.pid == model.runningApps.frontmostPID } ?? false,
                        showIndicators: appearance.showRunningIndicators,
                        islandWidth: model.islandWidth,
                        accessories: accessories
                    )
                }
            }

            if appearance.showHoverLabels, model.drag == nil, let id = model.hoveredEntryID,
               let entry = model.displayEntries.first(where: { $0.id == id }), entry.showsHoverLabel,
               let slot = layout.slot(id: id) {
                let iconTop = barBottom + metrics.verticalPadding + metrics.iconSize * slot.scale
                HoverLabel(text: entry.title, theme: theme, accessibility: model.accessibility)
                    .fixedSize()
                    .position(x: slot.midX, y: height - (iconTop + metrics.labelGap + metrics.labelHeight / 2))
                    .transition(.opacity)
                    .id(id)
            }

            if let drag = model.drag, case let .internalEntry(id) = drag.source,
               let entry = model.displayEntries.first(where: { $0.id == id }), let path = entry.iconPath {
                Image(nsImage: IconProvider.shared.icon(forPath: path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: metrics.iconSize * 1.06, height: metrics.iconSize * 1.06)
                    .opacity(drag.removeIntent ? 0.5 : 0.96)
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 6)
                    .position(x: drag.location.x, y: height - drag.location.y)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: model.containerSize.width, height: height, alignment: .topLeading)
        .animation(Motion.animation(.hover, reduceMotion: model.accessibility.reduceMotion), value: model.hoveredEntryID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("dock.accessibility.label", "PulseDock"))
    }
}

private extension DockEntry {
    var showsHoverLabel: Bool {
        switch kind {
        case .application, .folder, .trash: true
        case let .widget(placement): placement.kind == .quickLaunch
        default: false
        }
    }
}

extension TransparencyLevel {
    var surfaceOpacity: PulseGlassSurface.Opacity {
        switch self {
        case .clear: .clear
        case .standard: .standard
        case .opaque: .opaque
        }
    }
}

extension BorderStyle {
    var emphasis: Double {
        switch self {
        case .none: 0
        case .subtle: 1
        case .defined: 1.8
        }
    }
}

/// One entry of the bar.
struct DockEntryView: View {
    let entry: DockEntry
    let slot: DockSlotLayout
    let metrics: DockMetrics
    let theme: Theme
    let containerHeight: Double
    let barBottom: Double
    let presence: Double
    let isPressed: Bool
    let isDropTarget: Bool
    let isLaunching: Bool
    let isFrontmost: Bool
    let showIndicators: Bool
    let islandWidth: Double
    let accessories: DockAccessories

    var body: some View {
        switch entry.kind {
        case .application, .folder, .trash:
            iconEntry
        case .divider:
            Rectangle()
                .fill(theme.divider)
                .frame(width: metrics.dividerWidth, height: metrics.iconSize * 0.56 * presence)
                .position(x: slot.midX, y: containerHeight - barBottom - metrics.barHeight / 2)
                .accessibilityHidden(true)
        case .agentPulse:
            let width = max(0, (slot.width - metrics.spacing))
            accessories.island()
                .frame(width: width, height: metrics.iconSize)
                .opacity(presence)
                .position(x: slot.midX, y: containerHeight - barBottom - metrics.barHeight / 2)
        case let .widget(placement):
            if placement.kind == .quickLaunch {
                iconEntry
            } else {
                let size = CGSize(width: max(0, slot.width - metrics.spacing), height: metrics.iconSize)
                accessories.widget(placement, size)
                    .frame(width: size.width, height: size.height)
                    .opacity(presence)
                    .position(x: slot.midX, y: containerHeight - barBottom - metrics.barHeight / 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { accessories.activate(entry) }
            }
        case .placeholder:
            EmptyView()
        }
    }

    private var iconImage: NSImage {
        switch entry.kind {
        case .trash:
            return IconProvider.shared.systemIcon(named: accessories.trashIsFull() ? "FullTrashIcon" : "TrashIcon")
        case let .widget(placement) where placement.kind == .quickLaunch:
            return IconProvider.shared.systemIcon(named: "GenericFolderIcon")
        default:
            return entry.iconPath.map { IconProvider.shared.icon(forPath: $0) } ?? NSWorkspace.shared.icon(for: .application)
        }
    }

    private var iconEntry: some View {
        let size = metrics.iconSize * slot.scale * presence
        let iconCenterY = barBottom + metrics.verticalPadding + size / 2
        return ZStack {
            Image(nsImage: iconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .brightness(isPressed ? -0.14 : 0)
                .scaleEffect(isPressed ? 0.96 : 1)
                .opacity(entry.isMissing ? 0.38 : presence)
                .overlay {
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .strokeBorder(theme.tone(.working), lineWidth: 2)
                    }
                }
                .position(x: slot.midX, y: containerHeight - iconCenterY)

            if showIndicators, let running = entry.running {
                RunningIndicator(isFrontmost: isFrontmost, isHidden: running.isHidden, isLaunching: isLaunching, theme: theme, size: metrics.indicatorSize)
                    .opacity(presence)
                    .position(x: slot.midX, y: containerHeight - (barBottom + max(3, metrics.verticalPadding * 0.42)))
            } else if showIndicators, isLaunching {
                RunningIndicator(isFrontmost: false, isHidden: false, isLaunching: true, theme: theme, size: metrics.indicatorSize)
                    .position(x: slot.midX, y: containerHeight - (barBottom + max(3, metrics.verticalPadding * 0.42)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { accessories.activate(entry) }
    }

    private var accessibilityValue: String {
        if entry.isMissing { return tr("dock.accessibility.missing", "Not found") }
        guard let running = entry.running else { return "" }
        if isFrontmost { return tr("dock.accessibility.active", "Active") }
        if running.isHidden { return tr("dock.accessibility.hidden", "Running, hidden") }
        return tr("dock.accessibility.running", "Running")
    }
}

/// Dot under running apps; wider for the frontmost app, hollow when hidden, breathing while
/// the app launches (static with Reduce Motion).
struct RunningIndicator: View {
    let isFrontmost: Bool
    let isHidden: Bool
    let isLaunching: Bool
    let theme: Theme
    let size: Double
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(isHidden ? AnyShapeStyle(Color.clear) : AnyShapeStyle(theme.runningIndicator))
            .overlay(Capsule().strokeBorder(theme.runningIndicator.opacity(isHidden ? 0.9 : 0), lineWidth: 1))
            .frame(width: isFrontmost ? size * 2.6 : size, height: size)
            .opacity(isLaunching && !reduceMotion ? (breathing ? 0.25 : 1) : 1)
            .onAppear { startBreathingIfNeeded() }
            .onChange(of: isLaunching) { startBreathingIfNeeded() }
            .accessibilityHidden(true)
    }

    private func startBreathingIfNeeded() {
        guard isLaunching, !reduceMotion else {
            breathing = false
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathing = true }
    }
}

/// Name label above the hovered icon.
struct HoverLabel: View {
    let text: String
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        Text(text)
            .font(PulseTypography.dockLabel)
            .foregroundStyle(theme.labelText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                PulseGlassSurface(theme: theme, cornerRadius: 12, accessibility: accessibility, showsShadow: true, legibility: .content)
            }
            .accessibilityHidden(true)
    }
}
