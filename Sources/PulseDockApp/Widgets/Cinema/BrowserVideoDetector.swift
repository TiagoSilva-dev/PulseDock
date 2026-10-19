import AppKit
import Diagnostics
import DockCore
import Observation
import WidgetCore

/// Finds the YouTube video open in the user's browser through each browser's official
/// AppleScript dictionary (Safari, Chrome, Brave, Edge, Vivaldi, Arc).
///
/// There is no public API for the system's "Now Playing" information (MediaRemote is
/// private), so this is the supported way. It is opt-in: macOS asks once per browser for
/// Automation consent. Only running browsers are queried (never launched), only YouTube tabs
/// leave the script, and nothing is stored. It runs when the Cinema panel opens and when the
/// user leaves a browser, never on a timer.
@Observable
final class BrowserVideoDetector {
    enum Issue: Equatable {
        case permissionDenied(BrowserKind)
    }

    private(set) var tab: BrowserVideoTab?
    private(set) var issue: Issue?
    private(set) var isDetecting = false
    /// Running browsers that can be asked (for the empty-state text).
    private(set) var runningBrowsers: [BrowserKind] = []

    @ObservationIgnored private var recency: [BrowserKind] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pending = false
    @ObservationIgnored var isEnabled: () -> Bool = { false }

    init() {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.flatMap(BrowserKind.init(rawValue:)) {
            recency = [front]
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let browser = Self.browser(in: note)
            MainActor.assumeIsolated { if let browser { self?.markRecent(browser) } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let browser = Self.browser(in: note)
            MainActor.assumeIsolated { if browser != nil { self?.detect(userInitiated: false) } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let browser = Self.browser(in: note)
            MainActor.assumeIsolated { if let browser, self?.tab?.browser == browser { self?.tab = nil } }
        })
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        tab = nil
        issue = nil
    }

    private nonisolated static func browser(in note: Notification) -> BrowserKind? {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier.flatMap(BrowserKind.init(rawValue:))
    }

    private func markRecent(_ browser: BrowserKind) {
        recency.removeAll { $0 == browser }
        recency.insert(browser, at: 0)
    }

    /// `userInitiated` allows a long timeout, because the first query waits for the user to
    /// answer the macOS consent prompt.
    func detect(userInitiated: Bool) {
        guard isEnabled() else { return }
        if isDetecting {
            pending = true
            return
        }
        let running = BrowserKind.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).isEmpty }
        runningBrowsers = running
        guard !running.isEmpty else {
            tab = nil
            issue = nil
            return
        }
        isDetecting = true
        let timeout: TimeInterval = userInitiated ? 60 : 20
        let recency = recency
        Task.detached(priority: .utility) {
            var tabs: [BrowserVideoTab] = []
            var denied: BrowserKind?
            for browser in running {
                let result = AppleScriptRunner.runSynchronously(BrowserVideoScript.listSource(for: browser), timeout: timeout)
                if result.isPermissionDenied { denied = denied ?? browser }
                tabs += BrowserVideoScript.parse(result.output, browser: browser)
            }
            let best = BrowserVideoScript.best(tabs, recency: recency + BrowserKind.allCases.filter { !recency.contains($0) })
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isDetecting = false
                self.tab = best
                self.issue = best == nil ? denied.map(Issue.permissionDenied) : nil
                DiagnosticsRecorder.shared.record(.info, "widgets", "browser video detection: \(tabs.count) YouTube tab(s)")
                if self.pending {
                    self.pending = false
                    self.detect(userInitiated: false)
                }
            }
        }
    }

    /// Brings the tab to the front of its browser.
    func reveal(_ tab: BrowserVideoTab) {
        AppleScriptRunner.run(BrowserVideoScript.revealSource(for: tab), timeout: 10)
    }

    /// Pauses the page's video and returns its position, when the browser allows JavaScript
    /// from Apple Events; otherwise nil (the URL's start time is used).
    func handOff(_ tab: BrowserVideoTab, completion: @escaping @MainActor @Sendable (Int?) -> Void) {
        guard let source = BrowserVideoScript.handOffSource(for: tab) else {
            completion(nil)
            return
        }
        AppleScriptRunner.execute(source, timeout: 4) { result in
            completion(result.error == nil ? Int(result.output) : nil)
        }
    }

    func clear() { tab = nil }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
