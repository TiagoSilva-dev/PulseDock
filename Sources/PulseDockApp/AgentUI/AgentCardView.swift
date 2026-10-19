import AgentCore
import AppKit
import DockRendering
import SwiftUI

/// Everything the card can ask the app to do.
@MainActor
struct AgentCardActions {
    var openSession: (SessionKey) -> Void
    var revealProject: (SessionKey) -> Void
    var copyPath: (SessionKey) -> Void
    var showEvents: (SessionKey) -> Void
    var openMissionControl: () -> Void
    var openAgentSettings: () -> Void
    var startDemo: () -> Void
    var respond: (SessionKey, AttentionRequest, String) -> Void
    var togglePrivacy: () -> Void
}

/// The panel anchored to the Agent Pulse island.
struct AgentCardView: View {
    let store: AgentStore
    let integrations: IntegrationsManager
    let managed: CodexManagedService
    let settings: SettingsStore
    let accessibility: AccessibilityOptions
    let actions: AgentCardActions
    @State private var expanded: Set<SessionKey> = []
    @State private var appeared = false
    @FocusState private var focused: SessionKey?
    /// The focus highlight appears only once the keyboard is used: SwiftUI focuses the first row
    /// automatically when the panel opens, which would otherwise look like a selection.
    @State private var keyboardNavigation = false

    private var theme: Theme { Theme.theme(for: settings.settings.effectiveTheme) }
    private var text: AgentText { store.text }

    var body: some View {
        let sessions = store.summary.sessions
        VStack(spacing: 0) {
            header(sessions)
            if sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(sessions) { presentation in
                            SessionRow(
                                presentation: presentation,
                                store: store,
                                text: text,
                                theme: theme,
                                isManaged: managed.owns(presentation.id),
                                isExpanded: expanded.contains(presentation.id),
                                actions: actions,
                                isFocused: keyboardNavigation && focused == presentation.id,
                                toggleExpanded: { toggle(presentation.id) }
                            )
                            .focusable()
                            .focusEffectDisabled()
                            .focused($focused, equals: presentation.id)
                            .onKeyPress(.return) {
                                actions.openSession(presentation.id)
                                return .handled
                            }
                        }
                    }
                    .padding(10)
                }
                .scrollIndicators(.automatic)
                .onKeyPress(keys: [.tab, .upArrow, .downArrow, .return, .space]) { _ in
                    keyboardNavigation = true
                    return .ignored
                }
            }
            footer
        }
        .frame(width: 392)
        .background {
            PulseGlassSurface(theme: theme, cornerRadius: PanelMetrics.cornerRadius, accessibility: accessibility,
                              opacity: settings.settings.appearance.transparency.surfaceOpacity, legibility: .content)
        }
        .environment(\.colorScheme, theme.forcedColorScheme ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
        .scaleEffect(appeared ? 1 : 0.97, anchor: .bottom)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(Motion.animation(.panel, reduceMotion: accessibility.reduceMotion)) { appeared = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("card.accessibility", "AI Activity"))
    }

    private func toggle(_ key: SessionKey) {
        withAnimation(Motion.animation(.micro, reduceMotion: accessibility.reduceMotion)) {
            if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        }
    }

    // MARK: Header and footer

    private func header(_ sessions: [SessionPresentation]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tr("card.title", "AI Activity"))
                        .font(PulseTypography.panelTitle)
                    if store.isDemoRunning {
                        DemoBadge().help(tr("card.demo", "Demo data"))
                    }
                }
                Text(summaryLine(sessions))
                    .font(PulseTypography.panelCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: actions.togglePrivacy) {
                Image(systemName: settings.settings.privacy.privacyMode ? "eye.slash.fill" : "eye")
            }
            .buttonStyle(.borderless)
            .help(settings.settings.privacy.privacyMode ? tr("card.privacy.on", "Privacy Mode is on") : tr("card.privacy.off", "Turn on Privacy Mode"))
            .accessibilityLabel(tr("card.privacy.toggle", "Privacy Mode"))
            Button(action: actions.openMissionControl) {
                Image(systemName: "rectangle.3.group")
            }
            .buttonStyle(.borderless)
            .help(tr("card.missionControl", "Open AI Mission Control"))
            .accessibilityLabel(tr("card.missionControl", "Open AI Mission Control"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func summaryLine(_ sessions: [SessionPresentation]) -> String {
        guard !sessions.isEmpty else { return tr("card.summary.none", "No active sessions") }
        var parts: [String] = []
        let working = sessions.filter { $0.category == .working }.count
        let attention = sessions.filter { $0.category == .attention }.count
        let failed = sessions.filter { $0.category == .failure }.count
        let done = sessions.filter { $0.category == .recentCompletion }.count
        if working > 0 { parts.append(tr("card.summary.working", "%ld working", working)) }
        if attention > 0 { parts.append(trp("card.summary.attention", one: "%ld needs you", other: "%ld need you", attention)) }
        if failed > 0 { parts.append(tr("card.summary.failed", "%ld failed", failed)) }
        if done > 0 { parts.append(trp("card.summary.done", one: "%ld finished", other: "%ld finished", done)) }
        if parts.isEmpty { parts.append(trp("card.summary.quiet", one: "%ld session, all quiet", other: "%ld sessions, all quiet", sessions.count)) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ForEach([AgentProvider.claudeCode, .codex], id: \.self) { provider in
                IntegrationChip(provider: provider, state: integrations.connectionState(for: provider), theme: theme)
                    .onTapGesture { actions.openAgentSettings() }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
    }

    private var emptyState: some View {
        let anyConnected = [AgentProvider.claudeCode, .codex].contains { provider in
            switch integrations.connectionState(for: provider) {
            case .receiving, .waitingForFirstEvent, .awaitingTrust: true
            default: false
            }
        }
        return VStack(spacing: 10) {
            Image(systemName: anyConnected ? "moon.zzz" : "waveform.path.ecg")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(anyConnected ? tr("card.empty.quiet.title", "All quiet") : tr("card.empty.connect.title", "Connect your agents"))
                .font(PulseTypography.panelHeadline)
            Text(anyConnected
                 ? tr("card.empty.quiet.body", "Sessions appear here as soon as an agent starts working.")
                 : tr("card.empty.connect.body", "PulseDock follows Claude Code and Codex through their official hooks. Nothing is installed without your review."))
                .font(PulseTypography.panelBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !anyConnected {
                    Button(tr("card.empty.connect.button", "Connect…"), action: actions.openAgentSettings)
                        .buttonStyle(.borderedProminent)
                }
                Button(tr("card.empty.demo", "Show Demo"), action: actions.startDemo)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }
}

/// One session in the card.
struct SessionRow: View {
    let presentation: SessionPresentation
    let store: AgentStore
    let text: AgentText
    let theme: Theme
    let isManaged: Bool
    let isExpanded: Bool
    let actions: AgentCardActions
    var isFocused = false
    let toggleExpanded: () -> Void
    @State private var hovering = false

    private var session: AgentSession { presentation.session }

    var body: some View {
        let tone = AgentText.tone(presentation.state)
        let project = store.project(for: session)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                AgentGlyph(provider: session.provider, size: 28)
                    .overlay(Circle().strokeBorder(theme.tone(tone), lineWidth: presentation.category == .attention ? 2 : 0).padding(-3))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.provider.displayName)
                            .font(PulseTypography.panelHeadline)
                            .lineLimit(1)
                            .layoutPriority(2)
                        Text("·").foregroundStyle(.tertiary)
                        ProjectDot(project: project, privacy: text.privacyMode, size: 7)
                        Text(text.project(project))
                            .font(PulseTypography.panelHeadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if presentation.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                        if presentation.isMuted { Image(systemName: "bell.slash.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                        Spacer(minLength: 6)
                        StateChip(state: presentation.state, confidence: presentation.confidence, text: text, theme: theme)
                            .fixedSize()
                            .layoutPriority(3)
                    }
                    Text(text.headline(for: presentation))
                        .font(PulseTypography.panelBody)
                        .foregroundStyle(presentation.category == .attention ? theme.tone(.attention) : .primary)
                        .lineLimit(1)
                    if presentation.category != .attention, let detail = text.activityDetail(session.activity) {
                        Text(detail)
                            .font(PulseTypography.mono)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    metaLine(project: project)
                        .padding(.top, 1)
                }
            }
            if presentation.category == .attention, let request = session.pendingAttention {
                AttentionBlock(request: request, session: session, text: text, theme: theme, isManaged: isManaged, actions: actions)
            }
            progressAndSubagents
            if isExpanded { subagentList }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(rowStroke, lineWidth: isFocused ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.openSession(session.key) }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: tr("card.action.open", "Open session")) { actions.openSession(session.key) }
    }

    private var rowStroke: Color {
        if isFocused { return Color.accentColor.opacity(0.55) }
        return presentation.category == .attention ? theme.tone(.attention).opacity(0.35) : .clear
    }

    private func metaLine(project: ProjectInfo?) -> some View {
        HStack(spacing: 6) {
            if session.isDemo { DemoBadge() }
            Image(systemName: "clock").font(.system(size: 9.5))
            Text(timeText).fixedSize()
            if let host = hostText {
                Text("·")
                Text(host).lineLimit(1)
            }
            if let title = text.title(for: session), title.caseInsensitiveCompare(project?.name ?? "") != .orderedSame {
                Text("·")
                Text(title).lineLimit(1).truncationMode(.middle)
            }
            if session.collectionMethods.contains(.codexNotify), !session.capabilities.observesTools {
                Text("·")
                Text(tr("card.turnEndOnly", "turn-end only")).italic()
            }
        }
        .font(PulseTypography.panelCaption)
        .foregroundStyle(.secondary)
    }

    private var timeText: String {
        let now = Date()
        switch presentation.state {
        case .working:
            if let start = session.currentTurn?.startedAt { return tr("card.time.activeFor", "Active for %@", Formatting.duration(now.timeIntervalSince(start))) }
        case .waitingUser:
            if let since = session.pendingAttention?.requestedAt { return tr("card.time.waitingFor", "Waiting %@", Formatting.duration(now.timeIntervalSince(since))) }
        default:
            break
        }
        return Formatting.relative(session.lastStateChangeAt, now: now)
    }

    private var hostText: String? {
        guard !text.privacyMode, let origin = session.origin else { return nil }
        if let id = origin.hostAppBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return origin.tty.map { "\(name) · \($0)" } ?? name
        }
        return origin.terminalProgram
    }

    @ViewBuilder
    private var progressAndSubagents: some View {
        let progress = ProgressEvaluator.progress(for: session, effectiveState: presentation.state)
        let subagents = session.subagents.values.filter { $0.status == .running }.count
        let totalSubagents = session.subagents.count
        if progress.fraction != nil || totalSubagents > 0 {
            HStack(spacing: 10) {
                if case let .determinate(completed, total, source) = progress {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(completed), total: Double(total))
                            .progressViewStyle(.linear)
                            .tint(theme.tone(.working))
                            .frame(width: 80)
                        Text(source == "tasks" ? tr("card.progress.tasks", "Tasks · %ld of %ld", completed, total)
                                               : tr("card.progress.steps", "Steps · %ld of %ld", completed, total))
                            .font(PulseTypography.panelCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if totalSubagents > 0 {
                    Button(action: toggleExpanded) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.2.wave.2")
                            Text(subagents > 0 ? trp("card.subagents.running", one: "%ld subagent running", other: "%ld subagents running", subagents)
                                               : trp("card.subagents.total", one: "%ld subagent", other: "%ld subagents", totalSubagents))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(PulseTypography.panelCaption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 38)
        }
    }

    private var subagentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.subagents.values.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) { subagent in
                HStack(spacing: 6) {
                    Image(systemName: subagent.status == .running ? "circle.dotted" : (subagent.status == .completed ? "checkmark.circle" : "questionmark.circle"))
                        .foregroundStyle(subagent.status == .running ? theme.tone(.working) : .secondary)
                    Text(subagent.type ?? tr("card.subagent.untyped", "Subagent"))
                    if let description = subagent.description, !text.privacyMode {
                        Text(description).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let started = subagent.startedAt {
                        Text(Formatting.duration((subagent.endedAt ?? Date()).timeIntervalSince(started)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(PulseTypography.panelCaption)
            }
        }
        .padding(.leading, 38)
        .transition(.opacity)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(tr("card.action.open", "Open session")) { actions.openSession(session.key) }
        Button(tr("card.action.reveal", "Show project in Finder")) { actions.revealProject(session.key) }
        Button(tr("card.action.copyPath", "Copy project path")) { actions.copyPath(session.key) }
        Button(tr("card.action.events", "Show events")) { actions.showEvents(session.key) }
        Divider()
        Button(presentation.isPinned ? tr("card.action.unpin", "Unpin") : tr("card.action.pin", "Pin to top")) { store.togglePin(session.key) }
        Button(presentation.isMuted ? tr("card.action.unmute", "Unmute") : tr("card.action.mute", "Mute")) { store.toggleMute(session.key) }
        if session.lifecycle == .ended || presentation.state.isQuiescent {
            Button(tr("card.action.dismiss", "Remove from list")) { store.dismiss(session.key) }
        }
    }
}

struct ProjectDot: View {
    let project: ProjectInfo?
    let privacy: Bool
    var size: Double = 10

    var body: some View {
        let hue = privacy ? 0 : (project?.hue ?? 0)
        Circle()
            .fill(privacy ? Color.gray : Color(hue: hue, saturation: 0.55, brightness: 0.9))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct StateChip: View {
    let state: SessionState
    let confidence: Confidence
    let text: AgentText
    let theme: Theme

    var body: some View {
        let tone = AgentText.tone(state)
        HStack(spacing: 4) {
            Image(systemName: AgentText.symbol(state))
                .font(.system(size: 9.5, weight: .semibold))
            Text(text.state(state))
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
            if confidence == .inferred {
                Image(systemName: "questionmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .help(text.confidence(.inferred))
            }
        }
        .foregroundStyle(theme.tone(tone))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.tone(tone).opacity(0.13)))
        .accessibilityElement(children: .combine)
    }
}

struct IntegrationChip: View {
    let provider: AgentProvider
    let state: IntegrationsManager.ConnectionState
    let theme: Theme
    /// Off where the provider's name is already shown next to the chip.
    var showsProvider = true

    var body: some View {
        let (tone, label) = describe()
        HStack(spacing: 5) {
            Circle().fill(theme.tone(tone)).frame(width: 6, height: 6)
            Text(showsProvider ? "\(provider.displayName) · \(label)" : label)
                .font(PulseTypography.panelCaption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help(tr("card.integration.help", "Agent integration settings"))
    }

    private func describe() -> (StatusTone, String) {
        switch state {
        case .agentNotFound: (.offline, tr("integration.chip.notFound", "not found"))
        case .notConnected: (.unknown, tr("integration.chip.notConnected", "not connected"))
        case .waitingForFirstEvent: (.idle, tr("integration.chip.ready", "ready"))
        case .awaitingTrust: (.attention, tr("integration.chip.trust", "trust hooks in Codex"))
        case .receiving: (.success, tr("integration.chip.connected", "connected"))
        case .needsAttention: (.attention, tr("integration.chip.attention", "needs repair"))
        }
    }
}

/// Details of a pending request; decision buttons only for sessions whose integration can
/// officially answer (Codex Managed Mode).
struct AttentionBlock: View {
    let request: AttentionRequest
    let session: AgentSession
    let text: AgentText
    let theme: Theme
    let isManaged: Bool
    let actions: AgentCardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let detail = text.attentionDetail(request) {
                Text(detail)
                    .font(PulseTypography.mono)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            }
            if let reason = request.info.reason, !text.privacyMode {
                Text(reason).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
            }
            if isManaged, !request.info.availableDecisions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(request.info.availableDecisions, id: \.self) { decision in
                        Button(Self.label(decision)) { actions.respond(session.key, request, decision) }
                            .buttonStyle(.bordered)
                            .tint(decision.hasPrefix("accept") ? theme.tone(.working) : nil)
                    }
                }
                .controlSize(.small)
            } else {
                // Observation-only integrations: the way to answer is the session itself; the
                // note says why there is no Approve button here.
                Button {
                    actions.openSession(session.key)
                } label: {
                    Label(tr("card.attention.respond", "Respond in the session"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(tr("card.attention.observeOnly", "PulseDock observes this session and does not answer for you."))
                    .font(PulseTypography.panelCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 38)
    }

    static func label(_ decision: String) -> String {
        switch decision {
        case "accept": tr("approval.accept", "Approve")
        case "acceptForSession": tr("approval.acceptForSession", "Approve for session")
        case "decline": tr("approval.decline", "Decline")
        case "cancel": tr("approval.cancel", "Cancel turn")
        default: decision
        }
    }
}
