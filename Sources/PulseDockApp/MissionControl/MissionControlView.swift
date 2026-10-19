import AgentCore
import AppKit
import DockRendering
import SwiftUI

struct MissionControlView: View {
    @Bindable var model: MissionControlModel
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MissionSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            SessionListColumn(model: model)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)
        } detail: {
            if let presentation = model.selectedPresentation {
                SessionDetailView(model: model, presentation: presentation)
            } else {
                ContentUnavailableView(tr("mc.empty.title", "No session selected"), systemImage: "sparkles.rectangle.stack",
                                       description: Text(tr("mc.empty.body", "Choose a session to see its timeline.")))
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: Text(tr("mc.search", "Search sessions")))
        .toolbar {
            ToolbarItemGroup {
                Picker(tr("mc.filter.provider", "Provider"), selection: $model.providerFilter) {
                    Text(tr("mc.filter.allProviders", "All agents")).tag(AgentProvider?.none)
                    Text("Claude Code").tag(AgentProvider?.some(.claudeCode))
                    Text("Codex").tag(AgentProvider?.some(.codex))
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                Picker(tr("mc.filter.range", "Period"), selection: $model.dateRange) {
                    ForEach(MissionControlModel.DateRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                Picker(tr("mc.sort", "Sort"), selection: $model.sortOrder) {
                    ForEach(MissionControlModel.SortOrder.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
    }
}

// MARK: - Sidebar

private struct MissionSidebar: View {
    @Bindable var model: MissionControlModel

    var body: some View {
        List(selection: Binding(get: { model.filter }, set: { if let value = $0 { model.filter = value } })) {
            Section(tr("mc.sidebar.sessions", "Sessions")) {
                row(.all, tr("mc.filter.all", "All sessions"), "square.stack.3d.up")
                row(.attention, tr("mc.filter.attention", "Needs attention"), "exclamationmark.circle")
                row(.inProgress, tr("mc.filter.inProgress", "In progress"), "circle.dotted")
                row(.finished, tr("mc.filter.finished", "Finished"), "checkmark.circle")
                row(.history, tr("mc.filter.history", "History"), "clock.arrow.circlepath")
            }
            if !model.projects.isEmpty {
                Section(tr("mc.sidebar.projects", "Projects")) {
                    ForEach(model.projects) { entry in
                        Label {
                            HStack(spacing: 5) {
                                Text(model.text.project(entry.info)).lineLimit(1)
                                if let hint = entry.hint, !model.text.privacyMode {
                                    Text(hint).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                if entry.isDemo { DemoBadge() }
                            }
                        } icon: {
                            ProjectDot(project: entry.info, privacy: model.text.privacyMode)
                        }
                        .tag(MissionControlModel.Filter.project(entry.info.rootPath))
                    }
                }
            }
            Section {
                Button {
                    model.services.openSettings(pane: .agents)
                } label: {
                    Label(tr("mc.sidebar.settings", "Agent settings"), systemImage: "gearshape")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ filter: MissionControlModel.Filter, _ title: String, _ symbol: String) -> some View {
        let count = model.count(for: filter)
        return Label(title, systemImage: symbol)
            .badge(count > 0 ? count : 0)
            .tag(filter)
    }
}

// MARK: - Session list

private struct SessionListColumn: View {
    @Bindable var model: MissionControlModel

    var body: some View {
        let groups = model.groups
        Group {
            if groups.isEmpty {
                ContentUnavailableView(tr("mc.list.empty.title", "No sessions"), systemImage: "moon.zzz",
                                       description: Text(tr("mc.list.empty.body", "Sessions from Claude Code and Codex appear here as they run.")))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.project?.rootPath) { group in
                            Section {
                                ForEach(group.sessions) { presentation in
                                    SessionCard(model: model, presentation: presentation, isSelected: model.selection == presentation.id)
                                        .onTapGesture { model.selection = presentation.id }
                                }
                            } header: {
                                ProjectHeader(project: group.project, text: model.text)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }
}

private struct ProjectHeader: View {
    let project: ProjectInfo?
    let text: AgentText

    var body: some View {
        HStack(spacing: 8) {
            ProjectDot(project: project, privacy: text.privacyMode)
            Text(text.project(project)).font(.system(size: 13, weight: .semibold))
            if let path = text.path(project?.rootPath) {
                Text(path).font(PulseTypography.panelCaption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .background(.bar.opacity(0.0))
    }
}

private struct SessionCard: View {
    let model: MissionControlModel
    let presentation: SessionPresentation
    let isSelected: Bool

    var body: some View {
        let session = presentation.session
        let theme = Theme.nativeGlass
        let tone = AgentText.tone(presentation.state)
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.tone(tone))
                .frame(width: 3)
                .opacity(presentation.state == .idle ? 0.35 : 1)
            AgentGlyph(provider: session.provider, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if session.isDemo {
                        DemoBadge()
                    }
                    Spacer()
                    StateChip(state: presentation.state, confidence: presentation.confidence, text: model.text, theme: theme)
                }
                Text(model.text.headline(for: presentation))
                    .font(PulseTypography.panelBody)
                    .foregroundStyle(presentation.category == .attention ? theme.tone(.attention) : .primary)
                HStack(spacing: 6) {
                    Text(Formatting.relative(session.lastEventAt))
                    Text("·")
                    Text(trp("mc.card.turns", one: "%ld turn", other: "%ld turns", session.turnCount))
                    if !session.subagents.isEmpty {
                        Text("·")
                        Text(trp("mc.card.subagents", one: "%ld subagent", other: "%ld subagents", session.subagents.count))
                    }
                    if let title = model.text.title(for: session) {
                        Text("·")
                        Text(title).lineLimit(1).truncationMode(.middle)
                    }
                }
                .lineLimit(1)
                .font(PulseTypography.panelCaption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Detail

private struct SessionDetailView: View {
    @Bindable var model: MissionControlModel
    let presentation: SessionPresentation

    private var session: AgentSession { presentation.session }
    private var text: AgentText { model.text }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                facts
                capabilities
                if presentation.category == .attention, let request = session.pendingAttention {
                    section(tr("mc.detail.attention", "Waiting for you")) {
                        AttentionBlock(request: request, session: session, text: text, theme: .nativeGlass,
                                       isManaged: model.services.managedCodex.owns(session.key), actions: cardActions)
                            .padding(.leading, -38)
                    }
                }
                progress
                subagents
                timeline
            }
            .padding(22)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var cardActions: AgentCardActions {
        let ui = model.services.agentUI
        return AgentCardActions(
            openSession: { ui.openSession($0) },
            revealProject: { _ in },
            copyPath: { _ in },
            showEvents: { _ in },
            openMissionControl: {},
            openAgentSettings: { model.services.openSettings(pane: .agents) },
            startDemo: {},
            respond: { key, request, decision in
                guard let session = model.store.engine.session(key) else { return }
                try? model.services.managedCodex.respond(to: request, in: session, decision: decision)
            },
            togglePrivacy: {}
        )
    }

    private var header: some View {
        let project = model.store.project(for: session)
        return HStack(alignment: .top, spacing: 14) {
            AgentGlyph(provider: session.provider, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.provider.displayName).font(.system(size: 20, weight: .semibold))
                    Text("·").foregroundStyle(.tertiary)
                    Text(text.project(project)).font(.system(size: 20, weight: .regular)).foregroundStyle(.secondary).lineLimit(1)
                    if session.isDemo { DemoBadge() }
                }
                Text(text.headline(for: presentation)).font(.system(size: 14, weight: .medium))
                HStack(spacing: 6) {
                    if let path = text.path(project?.rootPath ?? session.projectPath) {
                        Text(path).font(PulseTypography.mono).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                    }
                    if let title = text.title(for: session) {
                        Text("·").foregroundStyle(.tertiary)
                        Label(title, systemImage: "tag").font(PulseTypography.panelCaption).foregroundStyle(.secondary).lineLimit(1)
                            .help(tr("mc.detail.sessionName", "Session name given by the agent"))
                    }
                }
                actions.padding(.top, 8)
            }
            Spacer()
            StateChip(state: presentation.state, confidence: presentation.confidence, text: text, theme: .nativeGlass)
                .fixedSize()
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !session.isDemo {
                Button(tr("mc.action.open", "Open Session")) { model.services.agentUI.openSession(session.key) }
                    .buttonStyle(.borderedProminent)
            }
            if model.services.managedCodex.owns(session.key), presentation.state == .working || presentation.state == .waitingUser {
                Button(tr("mc.action.interrupt", "Interrupt")) {
                    Task { try? await model.services.managedCodex.interrupt(session) }
                }
            }
            Menu {
                Button(presentation.isPinned ? tr("card.action.unpin", "Unpin") : tr("card.action.pin", "Pin to top")) { model.store.togglePin(session.key) }
                Button(presentation.isMuted ? tr("card.action.unmute", "Unmute") : tr("card.action.mute", "Mute")) { model.store.toggleMute(session.key) }
                if let path = model.store.project(for: session)?.rootPath ?? session.projectPath {
                    Button(tr("card.action.copyPath", "Copy project path")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                    Button(tr("card.action.reveal", "Show project in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.regular)
    }

    private var facts: some View {
        let now = Date()
        return HStack(spacing: 0) {
            fact(tr("mc.fact.started", "Started"), Formatting.compactDateTime(session.startedAt ?? session.firstSeenAt, now: now))
            fact(tr("mc.fact.lastActivity", "Last activity"), Formatting.relative(session.lastEventAt, now: now))
            fact(tr("mc.fact.turns", "Turns"), "\(session.turnCount)")
            if let turn = session.currentTurn {
                fact(tr("mc.fact.toolsThisTurn", "Tools this turn"), "\(turn.toolCount)")
            } else {
                fact(tr("mc.fact.toolsLastTurn", "Tools last turn"), "\(session.lastTurn?.toolCount ?? 0)")
            }
            if let host = session.origin?.hostAppBundleID.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }), !text.privacyMode {
                fact(tr("mc.fact.host", "Runs in"), FileManager.default.displayName(atPath: host.path).replacingOccurrences(of: ".app", with: "") + (session.origin?.tty.map { " · \($0)" } ?? ""))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(PulseTypography.panelCaption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            Text(value).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
    }

    /// What this integration can actually see, so missing information is explained, not invented.
    private var capabilities: some View {
        let capabilities = session.capabilities
        let items: [(String, Bool)] = [
            (tr("mc.cap.tools", "Tools"), capabilities.observesTools),
            (tr("mc.cap.permissions", "Approvals"), capabilities.observesPermissions),
            (tr("mc.cap.turnEnd", "Turn end"), capabilities.observesTurnEnd),
            (tr("mc.cap.interrupts", "Interrupts"), capabilities.observesInterrupts),
            (tr("mc.cap.subagents", "Subagents"), capabilities.observesSubagents),
            (tr("mc.cap.liveness", "Process liveness"), capabilities.providesProcessLiveness),
            (tr("mc.cap.actions", "Can answer approvals"), capabilities.canAnswerApprovals),
        ]
        return section(tr("mc.detail.observability", "Observability")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.collectionMethods.sorted { $0.rawValue < $1.rawValue }.map(text.collection).joined(separator: " · "))
                    .font(PulseTypography.panelCaption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.0) { item in
                        Label(item.0, systemImage: item.1 ? "checkmark.circle.fill" : "minus.circle")
                            .font(PulseTypography.panelCaption)
                            .foregroundStyle(item.1 ? Color.primary : Color.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(item.1 ? 0.07 : 0.03)))
                    }
                }
                if !capabilities.observesInterrupts, capabilities.observesTools {
                    Text(tr("mc.cap.interruptNote", "Interruptions are not reported by this integration; PulseDock infers them when a new prompt arrives or the agent says it is idle."))
                        .font(PulseTypography.panelCaption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        let info = ProgressEvaluator.progress(for: session, effectiveState: presentation.state)
        if !session.tasks.isEmpty || session.plan != nil {
            section(tr("mc.detail.plan", "Plan and tasks")) {
                VStack(alignment: .leading, spacing: 8) {
                    if case let .determinate(completed, total, _) = info {
                        ProgressView(value: Double(completed), total: Double(total)) {
                            Text(tr("card.progress.tasks", "Tasks · %ld of %ld", completed, total)).font(PulseTypography.panelCaption)
                        }
                    }
                    ForEach(session.tasks) { task in
                        stepRow(title: text.privacyMode ? tr("mc.task.hidden", "Task") : (task.subject ?? task.id), status: task.status)
                    }
                    if session.tasks.isEmpty, let plan = session.plan {
                        ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                            stepRow(title: text.privacyMode ? tr("mc.task.hidden", "Task") : step.title, status: step.status)
                        }
                    }
                }
            }
        }
    }

    private func stepRow(title: String, status: TaskStatus) -> some View {
        Label {
            Text(title).font(PulseTypography.panelBody).strikethrough(status == .completed, color: .secondary)
        } icon: {
            Image(systemName: status == .completed ? "checkmark.circle.fill" : (status == .inProgress ? "circle.lefthalf.filled" : "circle"))
                .foregroundStyle(status == .completed ? Theme.nativeGlass.tone(.success) : (status == .inProgress ? Theme.nativeGlass.tone(.working) : .secondary))
        }
    }

    @ViewBuilder
    private var subagents: some View {
        if !session.subagents.isEmpty {
            section(tr("mc.detail.subagents", "Subagents")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                        Text(tr("mc.detail.parent", "Parent: %@", session.provider.displayName + " · " + String(session.sessionID.prefix(8))))
                    }
                    .font(PulseTypography.panelCaption)
                    .foregroundStyle(.secondary)
                    ForEach(session.subagents.values.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) { subagent in
                        HStack(spacing: 8) {
                            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 18).padding(.leading, 6)
                            Image(systemName: subagent.status == .running ? "circle.dotted" : (subagent.status == .completed ? "checkmark.circle" : "questionmark.circle"))
                                .foregroundStyle(subagent.status == .running ? Theme.nativeGlass.tone(.working) : .secondary)
                            Text(subagent.type ?? tr("card.subagent.untyped", "Subagent")).font(PulseTypography.panelBody)
                            Text(String(subagent.id.prefix(10))).font(PulseTypography.mono).foregroundStyle(.tertiary)
                            Spacer()
                            if let start = subagent.startedAt {
                                Text(Formatting.timeFormatter.string(from: start)).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
                            }
                            if let start = subagent.startedAt, let end = subagent.endedAt {
                                Text(Formatting.duration(end.timeIntervalSince(start))).font(PulseTypography.panelCaption).monospacedDigit()
                            }
                            Text(subagent.status == .running ? tr("mc.subagent.running", "running") : (subagent.status == .completed ? tr("mc.subagent.done", "finished") : tr("mc.subagent.unknown", "unknown")))
                                .font(PulseTypography.panelCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var timeline: some View {
        section(tr("mc.detail.timeline", "Timeline")) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Picker(tr("mc.timeline.filter", "Events"), selection: $model.eventKindFilter) {
                        Text(tr("mc.timeline.all", "All events")).tag(TimelineEntry.Kind?.none)
                        Text(tr("mc.timeline.tools", "Tools")).tag(TimelineEntry.Kind?.some(.tool))
                        Text(tr("mc.timeline.tests", "Tests")).tag(TimelineEntry.Kind?.some(.tests))
                        Text(tr("mc.timeline.approvals", "Approvals")).tag(TimelineEntry.Kind?.some(.approvalRequested))
                        Text(tr("mc.timeline.errors", "Failures")).tag(TimelineEntry.Kind?.some(.turnFailed))
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                    if model.isLoadingTimeline { ProgressView().controlSize(.small) }
                }
                .padding(.bottom, 8)
                if model.visibleTimeline.isEmpty, !model.isLoadingTimeline {
                    Text(tr("mc.timeline.empty", "No events recorded for this session."))
                        .font(PulseTypography.panelBody)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.visibleTimeline) { entry in
                    TimelineRow(entry: entry, text: text, isExpanded: model.expandedEntries.contains(entry.id)) {
                        if model.expandedEntries.contains(entry.id) { model.expandedEntries.remove(entry.id) } else { model.expandedEntries.insert(entry.id) }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }
}

// MARK: - Timeline row

struct TimelineRow: View {
    let entry: TimelineEntry
    let text: AgentText
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let theme = Theme.nativeGlass
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(color(theme).opacity(0.16)).frame(width: 26, height: 26)
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color(theme))
                }
                Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1).frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    if entry.count > 1 {
                        Text("×\(entry.count)").font(PulseTypography.badge).foregroundStyle(.secondary)
                    }
                    if let type = entry.subagentType, entry.subagentID != nil, entry.kind != .subagentStarted, entry.kind != .subagentStopped {
                        Text(type).font(PulseTypography.panelCaption).padding(.horizontal, 5).background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Spacer()
                    if let duration = entry.duration, duration >= 0.5 {
                        Text(Formatting.duration(duration)).font(PulseTypography.panelCaption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(Formatting.timeWithSecondsFormatter.string(from: entry.at)).font(PulseTypography.panelCaption).monospacedDigit().foregroundStyle(.secondary)
                }
                if let subtitle {
                    Text(subtitle).font(PulseTypography.mono).foregroundStyle(.secondary).lineLimit(isExpanded ? 6 : 1)
                }
                if isExpanded { details }
            }
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
        }
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            if entry.items.count > 1, !text.privacyMode {
                ForEach(entry.items, id: \.self) { item in
                    Text("• \(item)").font(PulseTypography.mono).foregroundStyle(.secondary)
                }
            }
            detail(tr("mc.timeline.source", "Source"), text.collection(entry.collection) + (entry.sourceEvent.map { " · \($0)" } ?? ""))
            detail(tr("mc.timeline.confidence", "Confidence"), text.confidence(entry.confidence))
            if let code = entry.tool?.exitCode { detail(tr("mc.timeline.exit", "Exit code"), "\(code)") }
            if let failure = entry.failure?.summary, !text.privacyMode { detail(tr("mc.timeline.failure", "Failure"), failure) }
            if let reason = entry.metadata["reason"] { detail(tr("mc.timeline.reason", "Reason"), reason) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(PulseTypography.panelCaption).foregroundStyle(.tertiary).frame(width: 90, alignment: .leading)
            Text(value).font(PulseTypography.panelCaption).textSelection(.enabled)
        }
    }

    private func color(_ theme: Theme) -> Color {
        switch entry.outcome {
        case .failed: return theme.tone(.failure)
        case .running: return entry.kind == .approvalRequested ? theme.tone(.attention) : theme.tone(.working)
        case .unknown: return theme.tone(.unknown)
        case .succeeded:
            switch entry.kind {
            case .turnCompleted: return theme.tone(.success)
            case .approvalRequested: return theme.tone(.attention)
            default: return .secondary
            }
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .sessionStarted: "play.circle"
        case .prompt: "text.bubble"
        case .tool:
            switch entry.activity {
            case .readingFiles?: "doc.text.magnifyingglass"
            case .searchingCode?: "magnifyingglass"
            case .editingCode?: "pencil.line"
            case .building?: "hammer"
            case .usingGit?: "arrow.triangle.branch"
            case .consultingWeb?: "globe"
            case .delegating?: "person.2.wave.2"
            case .planning?: "checklist"
            default: "terminal"
            }
        case .tests: "checkmark.seal"
        case .fileChanges: "doc.badge.gearshape"
        case .subagentStarted: "person.badge.plus"
        case .subagentStopped: "person.badge.clock"
        case .approvalRequested: "hand.raised"
        case .approvalResolved: "hand.thumbsup"
        case .error, .turnFailed: "xmark.octagon"
        case .turnCompleted: "checkmark.circle"
        case .turnInterrupted: "pause.circle"
        case .sessionEnded: "stop.circle"
        case .processExited: "power"
        case .notification: "bell"
        case .compaction: "archivebox"
        case .plan: "list.bullet.rectangle"
        case .task: "checklist"
        }
    }

    private var title: String {
        switch entry.kind {
        case .sessionStarted: return tr("timeline.sessionStarted", "Session started")
        case .prompt:
            if let command = entry.metadata["command"], !text.privacyMode { return tr("timeline.command", "Command %@", command) }
            return tr("timeline.prompt", "New instruction")
        case .tool:
            let activity = entry.activity.map { ActivityDescriptor(kind: $0, since: entry.at) }
            return text.activity(activity, session: AgentSession(key: SessionKey(provider: .demo, sessionID: "x"), firstSeenAt: entry.at)) ?? (entry.tool?.name ?? tr("timeline.tool", "Tool"))
        case .tests: return entry.outcome == .failed ? tr("timeline.testsFailed", "Tests failed") : (entry.outcome == .running ? tr("timeline.testsRunning", "Running tests") : tr("timeline.testsPassed", "Tests ran"))
        case .fileChanges: return tr("timeline.files", "Files changed")
        case .subagentStarted: return tr("timeline.subagentStarted", "Subagent started · %@", entry.subagentType ?? "")
        case .subagentStopped: return tr("timeline.subagentStopped", "Subagent finished · %@", entry.subagentType ?? "")
        case .approvalRequested: return tr("timeline.approvalRequested", "Approval requested")
        case .approvalResolved: return entry.outcome == .failed ? tr("timeline.approvalDenied", "Denied by auto mode") : tr("timeline.approvalResolved", "Approval answered")
        case .error, .turnFailed: return tr("timeline.turnFailed", "Turn failed")
        case .turnCompleted: return tr("timeline.turnCompleted", "Turn finished")
        case .turnInterrupted: return tr("timeline.turnInterrupted", "Turn interrupted")
        case .sessionEnded: return tr("timeline.sessionEnded", "Session ended")
        case .processExited: return tr("timeline.processExited", "Agent process exited")
        case .notification: return tr("timeline.notification", "Notification")
        case .compaction: return tr("timeline.compaction", "Context compaction")
        case .plan: return tr("timeline.plan", "Plan updated")
        case .task: return entry.outcome == .succeeded ? tr("timeline.taskCompleted", "Task completed") : tr("timeline.taskCreated", "Task created")
        }
    }

    private var subtitle: String? {
        guard !text.privacyMode else { return nil }
        switch entry.kind {
        case .tool, .tests:
            if entry.count > 1 { return entry.items.prefix(4).joined(separator: ", ") + (entry.items.count > 4 ? "…" : "") }
            return entry.tool?.summary ?? entry.tool.map { ToolClassifierDisplay.name($0.name) }
        case .approvalRequested, .approvalResolved:
            return [entry.attention?.toolName ?? entry.tool?.name, entry.attention?.summary ?? entry.tool?.summary].compactMap { $0 }.joined(separator: ": ")
        case .turnFailed, .error:
            return entry.failure?.summary ?? entry.failure?.code
        case .task:
            return entry.task?.subject
        case .fileChanges:
            return entry.items.joined(separator: ", ")
        case .sessionStarted:
            return entry.metadata["source"]
        case .sessionEnded, .processExited:
            return entry.metadata["reason"]
        default:
            return nil
        }
    }
}

enum ToolClassifierDisplay {
    static func name(_ tool: String) -> String { ToolClassifier.displayName(toolName: tool) }
}

/// Wrapping horizontal layout for capability pills.
struct FlowLayout: Layout {
    var spacing: Double = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: Double = 0
        var y: Double = 0
        var rowHeight: Double = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: Double = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
