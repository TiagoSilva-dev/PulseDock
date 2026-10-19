import AgentCore
import Foundation
import Observation
import Persistence

/// State of the AI Mission Control window: filters, search, history and the selected
/// session's timeline.
@Observable
final class MissionControlModel {
    enum Filter: Hashable {
        case all
        case attention
        case inProgress
        case finished
        case history
        case project(String)
    }

    enum DateRange: String, CaseIterable, Identifiable {
        case today
        case week
        case month
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: tr("mc.range.today", "Today")
            case .week: tr("mc.range.week", "Last 7 days")
            case .month: tr("mc.range.month", "Last 30 days")
            case .all: tr("mc.range.all", "All time")
            }
        }

        var start: Date? {
            let now = Date()
            switch self {
            case .today: return Calendar.current.startOfDay(for: now)
            case .week: return now.addingTimeInterval(-7 * 86_400)
            case .month: return now.addingTimeInterval(-30 * 86_400)
            case .all: return nil
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case priority
        case recent

        var id: String { rawValue }
        var title: String {
            switch self {
            case .priority: tr("mc.sort.priority", "Priority")
            case .recent: tr("mc.sort.recent", "Most recent")
            }
        }
    }

    var filter: Filter = .all { didSet { if filter != oldValue { reload() } } }
    var searchText = "" { didSet { if searchText != oldValue { scheduleReload() } } }
    var providerFilter: AgentProvider? { didSet { if providerFilter != oldValue { reload() } } }
    var stateFilter: SessionState? { didSet { if stateFilter != oldValue { reload() } } }
    var dateRange: DateRange = .week { didSet { if dateRange != oldValue { reload() } } }
    var sortOrder: SortOrder = .priority
    var eventKindFilter: TimelineEntry.Kind?
    var selection: SessionKey? { didSet { if selection != oldValue { loadTimeline() } } }
    var expandedEntries: Set<String> = []

    private(set) var historySessions: [AgentSession] = []
    private(set) var timeline: [TimelineEntry] = []
    private(set) var isLoadingTimeline = false

    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var liveRefreshTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    var store: AgentStore { services.agents }
    var text: AgentText { store.text }

    // MARK: Lists

    /// Live sessions (in memory) merged with persisted history for the chosen range.
    var presentations: [SessionPresentation] {
        let now = Date()
        let live = store.summary.sessions
        let liveKeys = Set(live.map(\.id))
        let history = historySessions.filter { !liveKeys.contains($0.key) }.map {
            AgentPresenter.present($0, now: now, policy: store.policy, processAlive: false)
        }
        var all: [SessionPresentation]
        switch filter {
        case .all: all = live + history
        case .attention: all = live.filter { $0.category == .attention }
        case .inProgress: all = live.filter { $0.category == .working || $0.state == .stale || $0.state == .unknown }
        case .finished: all = (live + history).filter { $0.state.isQuiescent || $0.session.lifecycle == .ended }
        case .history: all = history + live.filter { $0.session.lifecycle == .ended }
        case let .project(root): all = (live + history).filter { store.project(for: $0.session)?.rootPath == root }
        }
        if let providerFilter { all = all.filter { $0.session.provider == providerFilter } }
        if let stateFilter { all = all.filter { $0.state == stateFilter } }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            all = all.filter { presentation in
                let session = presentation.session
                let haystack = [store.project(for: session)?.name, session.projectPath, session.title, session.provider.displayName, session.sessionID]
                    .compactMap { $0?.lowercased() }
                return haystack.contains { $0.contains(query) }
            }
        }
        switch sortOrder {
        case .priority: return all.sorted(by: AgentPresenterOrdering.priority)
        case .recent: return all.sorted { $0.session.lastEventAt > $1.session.lastEventAt }
        }
    }

    /// Sessions grouped by project, in list order.
    var groups: [(project: ProjectInfo?, sessions: [SessionPresentation])] {
        var order: [String] = []
        var buckets: [String: (ProjectInfo?, [SessionPresentation])] = [:]
        for presentation in presentations {
            let project = store.project(for: presentation.session)
            let key = project?.rootPath ?? "~"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = (project, [])
            }
            buckets[key]?.1.append(presentation)
        }
        return order.compactMap { buckets[$0].map { (project: $0.0, sessions: $0.1) } }
    }

    /// A project in the sidebar. `hint` (the parent folder) is set only when two projects share
    /// a name, and `isDemo` marks projects that exist only in demo fixtures.
    struct ProjectEntry: Identifiable {
        var info: ProjectInfo
        var isDemo: Bool
        var hint: String?
        var id: String { info.rootPath }
    }

    var projects: [ProjectEntry] {
        var seen: [String: (info: ProjectInfo, demoOnly: Bool)] = [:]
        for session in store.summary.sessions.map(\.session) + historySessions {
            guard let project = store.project(for: session) else { continue }
            let demoOnly = (seen[project.rootPath]?.demoOnly ?? true) && session.isDemo
            seen[project.rootPath] = (project, demoOnly)
        }
        let names = seen.values.map { $0.info.name.lowercased() }
        return seen.values
            .map { entry in
                let collides = names.filter { $0 == entry.info.name.lowercased() }.count > 1
                // The parent folder tells same-named projects apart; the home folder shows as "~"
                // rather than the user's account name.
                let parentPath = (entry.info.rootPath as NSString).deletingLastPathComponent
                let parent = parentPath == NSHomeDirectory() ? "~" : (parentPath as NSString).lastPathComponent
                return ProjectEntry(info: entry.info, isDemo: entry.demoOnly, hint: collides && !entry.demoOnly ? parent : nil)
            }
            .sorted {
                if $0.isDemo != $1.isDemo { return !$0.isDemo }
                return $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending
            }
    }

    func count(for filter: Filter) -> Int {
        let live = store.summary.sessions
        switch filter {
        case .all: return live.count
        case .attention: return live.filter { $0.category == .attention }.count
        case .inProgress: return live.filter { $0.category == .working }.count
        case .finished: return live.filter { $0.state.isQuiescent }.count
        case .history, .project: return 0
        }
    }

    var selectedPresentation: SessionPresentation? {
        guard let selection else { return nil }
        return store.presentation(for: selection)
            ?? historySessions.first { $0.key == selection }.map {
                AgentPresenter.present($0, now: Date(), policy: store.policy, processAlive: false)
            }
    }

    var visibleTimeline: [TimelineEntry] {
        guard let eventKindFilter else { return timeline }
        return timeline.filter { $0.kind == eventKindFilter }
    }

    // MARK: Loading

    func focus(_ key: SessionKey) {
        filter = .all
        selection = key
    }

    func reload() {
        reloadTask?.cancel()
        let query = HistoryQuery(
            providers: providerFilter.map { [$0] } ?? [],
            states: stateFilter.map { [$0] } ?? [],
            projectPath: { if case let .project(root) = filter { return root } else { return nil } }(),
            text: searchText.isEmpty ? nil : searchText,
            from: dateRange.start,
            limit: 300
        )
        reloadTask = Task { @MainActor [weak self] in
            guard let self, let persistence = self.services.persistence else { return }
            let sessions = await persistence.history(query)
            guard !Task.isCancelled else { return }
            self.historySessions = sessions
            if self.selection == nil { self.selection = self.presentations.first?.id }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func liveChanged() {
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            if let selection = self.selection, self.store.engine.session(selection) != nil { self.loadTimeline(showSpinner: false) }
        }
    }

    func loadTimeline(showSpinner: Bool = true) {
        guard let key = selection else {
            timeline = []
            return
        }
        if showSpinner { isLoadingTimeline = true }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let events = await self.store.events(for: key)
            guard self.selection == key else { return }
            self.timeline = TimelineBuilder.build(events).reversed()
            self.isLoadingTimeline = false
        }
    }
}

/// Ordering shared with the Agent Card.
enum AgentPresenterOrdering {
    static func priority(_ lhs: SessionPresentation, _ rhs: SessionPresentation) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.category != rhs.category { return lhs.category < rhs.category }
        return lhs.session.lastEventAt > rhs.session.lastEventAt
    }
}
