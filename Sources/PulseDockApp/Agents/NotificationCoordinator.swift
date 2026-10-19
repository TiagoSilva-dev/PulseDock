import AgentCore
import AppKit
import Diagnostics
import Foundation
@preconcurrency import UserNotifications

/// Native notifications for agent events, with priorities, grouping and quiet hours.
///
/// - Only events that block progress (approvals, questions) and failures notify by default;
///   completions are opt-in, since the island already confirms them without interrupting.
/// - Requests arriving within a short window are grouped into one notification.
/// - Each session has one notification slot that newer ones replace.
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private let settings: SettingsStore
    private let store: AgentStore
    var onOpenSession: (SessionKey) -> Void = { _ in }
    private var pending: [(SessionKey, Kind, String)] = []
    private var flushTask: Task<Void, Never>?
    private var notifiedRequests = Set<String>()
    private var authorizationRequested = false

    enum Kind: String {
        case attention
        case failure
        case completion
    }

    init(settings: SettingsStore, store: AgentStore) {
        self.settings = settings
        self.store = store
        super.init()
        if Self.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// UserNotifications needs a real app bundle; `swift run` builds have none.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func handle(_ events: [AgentEvent]) {
        let preferences = settings.settings.notifications
        guard Self.isAvailable, preferences.enabled, !isQuietTime(preferences) else { return }
        let muted = store.muted
        for event in events where !muted.contains(event.sessionKey) {
            switch event.kind {
            case .permissionRequested where preferences.attention, .attentionNeeded where preferences.attention:
                let requestKey = "\(event.sessionKey.rawValue)#\(event.attention?.requestID ?? event.tool?.inputFingerprint ?? event.attention?.kind.rawValue ?? "")"
                guard !notifiedRequests.contains(requestKey) else { continue }
                notifiedRequests.insert(requestKey)
                if notifiedRequests.count > 500 { notifiedRequests.removeAll() }
                enqueue(event.sessionKey, .attention)
            case .turnFailed where preferences.failures:
                enqueue(event.sessionKey, .failure)
            case .turnCompleted where preferences.completions:
                enqueue(event.sessionKey, .completion)
            default:
                continue
            }
        }
    }

    /// Claude usage limit crossing 80% or 95% (once per window, decided by the ledger).
    func postUsageAlert(_ alert: UsageAlert) {
        let preferences = settings.settings.notifications
        guard Self.isAvailable, preferences.enabled, preferences.usageLimits, !isQuietTime(preferences) else { return }
        let content = UNMutableNotificationContent()
        let percent = Formatting.percent(alert.usedPercent / 100)
        switch alert.window {
        case .fiveHour: content.title = tr("notification.usage.fiveHour", "Claude · 5-hour limit at %@", percent)
        case .sevenDay: content.title = tr("notification.usage.sevenDay", "Claude · weekly limit at %@", percent)
        case .spend: content.title = tr("notification.usage.spend", "Claude · spend limit at %@", percent)
        }
        if let reset = alert.resetsAt {
            content.body = tr("notification.usage.resets", "Resets %@.", Formatting.reset(reset))
        }
        content.interruptionLevel = alert.threshold >= 95 ? .timeSensitive : .active
        if preferences.playSound { content.sound = .default }
        content.threadIdentifier = "pulsedock.usage"
        Task { @MainActor in
            guard await authorize() else { return }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pulsedock.usage.\(alert.window.rawValue)", content: content, trigger: nil))
        }
    }

    private func isQuietTime(_ preferences: NotificationSettings) -> Bool {
        guard preferences.quietHoursEnabled else { return false }
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if preferences.quietStart <= preferences.quietEnd {
            return minutes >= preferences.quietStart && minutes < preferences.quietEnd
        }
        return minutes >= preferences.quietStart || minutes < preferences.quietEnd
    }

    private func enqueue(_ key: SessionKey, _ kind: Kind) {
        pending.removeAll { $0.0 == key && $0.1 == kind }
        pending.append((key, kind, UUID().uuidString))
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        let batch = pending
        pending.removeAll()
        guard !batch.isEmpty else { return }
        Task { @MainActor in
            guard await authorize() else { return }
            let attention = batch.filter { $0.1 == .attention }
            if attention.count > 1 {
                await post(grouped: attention.map(\.0))
            } else if let first = attention.first {
                await post(single: first.0, kind: .attention)
            }
            for item in batch where item.1 != .attention {
                await post(single: item.0, kind: item.1)
            }
        }
    }

    /// Asks for permission once, the first time something is worth notifying.
    private func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            guard !authorizationRequested else { return false }
            authorizationRequested = true
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    private func content(for key: SessionKey, kind: Kind) -> UNMutableNotificationContent? {
        guard let presentation = store.presentation(for: key) else { return nil }
        let text = store.text
        let session = presentation.session
        let content = UNMutableNotificationContent()
        let demo = session.isDemo ? "[Demo] " : ""
        let project = text.project(store.project(for: session))
        content.title = "\(demo)\(session.provider.displayName) · \(project)"
        switch kind {
        case .attention:
            content.subtitle = text.attention(session.pendingAttention)
            content.body = text.attentionDetail(session.pendingAttention) ?? tr("notification.attention.body", "Open the session to respond.")
            content.interruptionLevel = .timeSensitive
        case .failure:
            content.subtitle = text.failure(session.recentFailure) ?? text.state(.failed)
            content.body = text.privacyMode ? "" : (session.recentFailure?.info.summary ?? "")
        case .completion:
            content.subtitle = text.state(.completed)
            content.body = tr("notification.completion.body", "The agent finished its turn and is waiting for you.")
            content.interruptionLevel = .passive
        }
        if settings.settings.notifications.playSound, kind != .completion { content.sound = .default }
        content.threadIdentifier = key.rawValue
        content.userInfo = ["session": key.rawValue]
        return content
    }

    private func post(single key: SessionKey, kind: Kind) async {
        guard let content = content(for: key, kind: kind) else { return }
        let request = UNNotificationRequest(identifier: "\(key.rawValue)#\(kind.rawValue)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func post(grouped keys: [SessionKey]) async {
        let content = UNMutableNotificationContent()
        content.title = trp("notification.grouped.title", one: "%ld agent needs you", other: "%ld agents need you", keys.count)
        let text = store.text
        content.body = keys.compactMap { key -> String? in
            guard let presentation = store.presentation(for: key) else { return nil }
            return "\(presentation.session.provider.shortName) · \(text.project(store.project(for: presentation.session))) — \(text.attention(presentation.session.pendingAttention))"
        }.joined(separator: "\n")
        content.interruptionLevel = .timeSensitive
        if settings.settings.notifications.playSound { content.sound = .default }
        content.userInfo = ["session": keys.first?.rawValue ?? ""]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pulsedock.grouped-attention", content: content, trigger: nil))
    }

    /// Withdraws notifications that no longer apply (the request was answered).
    func clearResolved() {
        guard Self.isAvailable else { return }
        let waiting = Set(store.summary.sessions.filter { $0.category == .attention }.map { "\($0.id.rawValue)#attention" })
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let stale = delivered.map(\.request.identifier).filter { $0.hasSuffix("#attention") && !waiting.contains($0) }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["session"] as? String
        await MainActor.run {
            if let raw, let key = SessionKey(rawValue: raw) { onOpenSession(key) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
