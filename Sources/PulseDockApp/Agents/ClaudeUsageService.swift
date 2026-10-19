import AgentCore
import ClaudeCodeAdapter
import Diagnostics
import Foundation
import Observation

/// Claude usage as reported by Claude Code's status line: 5-hour and weekly limits (Pro and
/// Max), spend limit (gateway), session cost estimate and context use.
///
/// Values only change when Claude Code runs the status line (after each assistant message),
/// so everything shown carries its age; nothing is estimated beyond the documented 5-hour
/// projection, which needs real growth across ten minutes.
@Observable
final class ClaudeUsageService {
    private(set) var ledger: ClaudeUsageLedger
    /// Installation state of PulseDock's status line (read from `IntegrationsManager`).
    @ObservationIgnored var connection: () -> ClaudeStatusLineInstaller.Status = { .notInstalled(hasOwn: false) }

    var isConnected: Bool {
        if case .installed = connection() { return true }
        return false
    }

    @ObservationIgnored private let data: WidgetDataStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var onAlert: (UsageAlert) -> Void = { _ in }

    init(data: WidgetDataStore) {
        self.data = data
        var ledger = data.data.claudeUsage
        ledger.prune(now: Date())
        self.ledger = ledger
    }

    func ingest(_ snapshot: ClaudeUsageSnapshot) {
        let alerts = ledger.apply(snapshot)
        alerts.forEach(onAlert)
        scheduleSave()
    }

    func limits(now: Date = Date()) -> UsageLimits? { ledger.currentLimits(now: now) }

    var lastUpdate: Date? { ledger.lastObservedAt }

    /// Status line updates arrive every few seconds while Claude works: persist at most twice
    /// a minute (and on sleep and quit through `flush`).
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        ledger.prune(now: Date())
        let ledger = ledger
        data.update { $0.claudeUsage = ledger }
    }
}
