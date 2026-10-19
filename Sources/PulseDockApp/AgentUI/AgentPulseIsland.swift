import AgentCore
import AppKit
import DockRendering
import SwiftUI

/// Provider identity: an original monogram badge (no third-party logos).
struct AgentGlyph: View {
    let provider: AgentProvider
    var size: Double = 18

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: Self.colors(provider), startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
            Text(Self.monogram(provider))
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }

    static func monogram(_ provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: "Cl"
        case .codex: "Cx"
        case .demo: "D"
        }
    }

    static func colors(_ provider: AgentProvider) -> [Color] {
        switch provider {
        case .claudeCode: [Color(.sRGB, red: 0.86, green: 0.55, blue: 0.38), Color(.sRGB, red: 0.66, green: 0.36, blue: 0.27)]
        case .codex: [Color(.sRGB, red: 0.36, green: 0.55, blue: 0.62), Color(.sRGB, red: 0.20, green: 0.31, blue: 0.40)]
        case .demo: [Color.gray, Color.gray.opacity(0.7)]
        }
    }
}

/// What the island shows, derived from the aggregate summary.
struct IslandContent: Equatable {
    enum Mode: Equatable {
        case empty
        case compact
        case activity
        case attention
        case completion
        case failure
    }

    var mode: Mode
    var providers: [AgentProvider]
    var text: String?
    var liveCount: Int
    var extraCount: Int
    var tone: StatusTone
    var isDemo: Bool
    var accessibilityText: String

    static func make(summary: AggregateSummary, text: AgentText, filter: AgentFilter) -> IslandContent {
        var sessions = summary.sessions
        if filter == .attentionOnly { sessions = sessions.filter { $0.category == .attention || $0.category == .failure } }
        let isDemo = sessions.contains { $0.session.isDemo }
        var providers: [AgentProvider] = []
        for presentation in sessions where !providers.contains(presentation.session.provider) {
            providers.append(presentation.session.provider)
        }
        providers = Array(providers.prefix(3))
        guard !sessions.isEmpty else {
            return IslandContent(mode: .empty, providers: [], text: nil, liveCount: 0, extraCount: 0, tone: .offline, isDemo: false,
                                 accessibilityText: tr("island.accessibility.empty", "No active agent sessions"))
        }
        func line(_ key: SessionKey) -> (SessionPresentation, String)? {
            guard let presentation = sessions.first(where: { $0.id == key }) else { return nil }
            return (presentation, "\(presentation.session.provider.shortName) · \(text.headline(for: presentation))")
        }
        let attentionCount = sessions.filter { $0.category == .attention && !$0.isMuted }.count
        let workingCount = sessions.filter { $0.category == .working }.count
        switch summary.mode {
        case let .attention(key):
            if let (_, label) = line(key) {
                let extra = attentionCount - 1
                return IslandContent(mode: .attention, providers: providers, text: label, liveCount: sessions.count, extraCount: max(0, extra),
                                     tone: .attention, isDemo: isDemo, accessibilityText: label)
            }
        case let .failure(key):
            if let (_, label) = line(key) {
                return IslandContent(mode: .failure, providers: providers, text: label, liveCount: sessions.count, extraCount: max(0, sessions.count - 1),
                                     tone: .failure, isDemo: isDemo, accessibilityText: label)
            }
        case let .completionFlash(key):
            if let (_, label) = line(key) {
                return IslandContent(mode: .completion, providers: providers, text: label, liveCount: sessions.count, extraCount: max(0, sessions.count - 1),
                                     tone: .success, isDemo: isDemo, accessibilityText: label)
            }
        case let .activity(key):
            if let (_, label) = line(key) {
                return IslandContent(mode: .activity, providers: providers, text: label, liveCount: sessions.count, extraCount: max(0, workingCount - 1),
                                     tone: .working, isDemo: isDemo, accessibilityText: label)
            }
        case .compact, .empty:
            break
        }
        let tone: StatusTone = sessions.contains { $0.category == .recentCompletion } ? .success : .idle
        let description = trp("island.accessibility.compact", one: "%ld agent session, none needs you", other: "%ld agent sessions, none needs you", sessions.count)
        return IslandContent(mode: .compact, providers: providers, text: nil, liveCount: sessions.count, extraCount: 0, tone: tone,
                             isDemo: isDemo, accessibilityText: description)
    }

    /// The dock slot width for a measured content row: padding on both sides, never narrower
    /// than a compact capsule and never wider than the island's maximum (text truncates there).
    static func slotWidth(contentWidth: Double, iconSize: Double) -> Double {
        (max(iconSize * 0.82, min(contentWidth + 2 * horizontalPadding, maximumWidth))).rounded(.up)
    }

    static let horizontalPadding = 12.0
    static let maximumWidth = 360.0
}

/// The capsule embedded in the dock.
struct AgentPulseIslandView: View {
    let store: AgentStore
    let settings: SettingsStore
    let accessibility: AccessibilityOptions
    let onWidthChange: (Double) -> Void

    var body: some View {
        let theme = Theme.theme(for: settings.settings.effectiveTheme)
        let content = IslandContent.make(summary: store.summary, text: store.text, filter: settings.activeWorkspace.agentFilter)
        let animate = settings.settings.appearance.animationsEnabled && !accessibility.reduceMotion
        GeometryReader { proxy in
            let height = min(proxy.size.height * 0.64, 36)
            ZStack {
                if content.mode != .empty, theme.ambientIntensity > 0 {
                    AmbientGlow(
                        color: NSColor(theme.tone(content.tone)),
                        intensity: glowIntensity(content.mode) * theme.ambientIntensity,
                        breathing: animate && (content.mode == .attention || content.mode == .activity),
                        cornerRadius: height / 2
                    )
                    .frame(width: proxy.size.width, height: height)
                }
                Capsule()
                    .fill(theme.islandFill)
                    .overlay(Capsule().strokeBorder(content.mode == .attention ? theme.tone(.attention).opacity(0.55) : theme.islandStroke, lineWidth: 1))
                    .frame(width: proxy.size.width, height: height)
                IslandContentRow(content: content, theme: theme, animate: animate)
                    .frame(height: height)
                    .padding(.horizontal, IslandContent.horizontalPadding)
                    .frame(width: proxy.size.width)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(Motion.animation(.panel, reduceMotion: accessibility.reduceMotion), value: content)
        // The slot width comes from measuring the real row (same fonts, badges and spacing),
        // so the dock never has to predict text metrics. The measuring copy is fixed-size and
        // hidden, so it cannot feed back into the width it reports.
        .background(alignment: .leading) {
            IslandContentRow(content: content, theme: theme, animate: false)
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width in
                    onWidthChange(IslandContent.slotWidth(contentWidth: width, iconSize: settings.settings.appearance.iconSize))
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("island.accessibility.label", "Agent Pulse"))
        .accessibilityValue(content.accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(tr("island.accessibility.hint", "Shows your AI agent sessions"))
    }

    private func glowIntensity(_ mode: IslandContent.Mode) -> Double {
        switch mode {
        case .attention: 0.85
        case .failure: 0.6
        case .completion: 0.65
        case .activity: 0.45
        case .compact, .empty: 0
        }
    }
}

private struct IslandContentRow: View {
    let content: IslandContent
    let theme: Theme
    let animate: Bool

    var body: some View {
        HStack(spacing: 6) {
            glyphs
            statusMark
            if let text = content.text {
                Text(text)
                    .font(PulseTypography.island)
                    .foregroundStyle(theme.labelText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                    .id(text)
            }
            if content.mode == .compact, content.liveCount > 1 {
                countBadge("\(content.liveCount)")
            } else if content.extraCount > 0 {
                countBadge("+\(content.extraCount)")
            }
            if content.isDemo { DemoBadge() }
        }
    }

    @ViewBuilder
    private var glyphs: some View {
        if content.providers.isEmpty {
            Image(systemName: "waveform.path")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.tone(.offline))
        } else {
            // Overlapping stack: the first (highest-priority) provider sits on top and each badge
            // is ringed in the capsule colour, so no monogram is covered by its neighbour.
            HStack(spacing: -4) {
                ForEach(Array(content.providers.enumerated()), id: \.element) { index, provider in
                    AgentGlyph(provider: provider, size: 18)
                        .padding(1.5)
                        .background(Circle().fill(theme.islandFill))
                        .zIndex(Double(content.providers.count - index))
                }
            }
            .padding(.horizontal, -1.5)
            .opacity(content.mode == .compact ? 0.85 : 1)
        }
    }

    @ViewBuilder
    private var statusMark: some View {
        switch content.mode {
        case .activity:
            PulseWaveIndicator(color: NSColor(theme.tone(.working)), animated: animate)
                .frame(width: 14, height: 12)
        case .attention:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.tone(.attention))
        case .completion:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.tone(.success))
        case .failure:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.tone(.failure))
        case .compact:
            Circle().fill(theme.tone(content.tone)).frame(width: 5, height: 5)
        case .empty:
            EmptyView()
        }
    }

    private func countBadge(_ text: String) -> some View {
        Text(text)
            .font(PulseTypography.badge)
            .monospacedDigit()
            .foregroundStyle(theme.labelText.opacity(0.85))
            .padding(.horizontal, 5)
            .frame(minWidth: 17, minHeight: 15)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
    }
}
