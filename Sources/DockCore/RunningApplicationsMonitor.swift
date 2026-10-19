import AppKit
import Diagnostics
import Foundation
import Observation

/// Snapshot of a running GUI application.
public struct RunningApp: Identifiable, Hashable, Sendable {
    public var id: pid_t { pid }
    public var pid: pid_t
    public var bundleIdentifier: String?
    public var bundleURL: URL?
    public var name: String
    public var isActive: Bool
    public var isHidden: Bool
    public var isFinishedLaunching: Bool
    public var launchDate: Date?

    public init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        bundleIdentifier = app.bundleIdentifier
        bundleURL = app.bundleURL
        name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App"
        isActive = app.isActive
        isHidden = app.isHidden
        isFinishedLaunching = app.isFinishedLaunching
        launchDate = app.launchDate
    }
}

/// Observes `NSWorkspace` for application lifecycle changes. Event driven: no polling.
@Observable
public final class RunningApplicationsMonitor {
    /// Regular (Dock-visible) applications in launch order.
    public private(set) var applications: [RunningApp] = []
    public private(set) var frontmostPID: pid_t?
    /// Bundle paths of apps the user just asked to open, used for launch feedback.
    public private(set) var launchingPaths: Set<String> = []

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// Called after the list of running apps or the frontmost app changes.
    @ObservationIgnored public var onChange: () -> Void = {}

    public init() {
        reload()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didLaunchApplicationNotification || name == NSWorkspace.didTerminateApplicationNotification,
                       let path {
                        self.launchingPaths.remove(path)
                    }
                    self.reload()
                }
            })
        }
    }

    public func markLaunching(path: String) {
        launchingPaths.insert(path)
        // Launch feedback must never stick if the app fails to start.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            self?.launchingPaths.remove(path)
        }
    }

    public func reload() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
            .map(RunningApp.init)
        var changed = false
        if running != applications {
            applications = running
            changed = true
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front != frontmostPID {
            frontmostPID = front
            changed = true
        }
        if changed { onChange() }
    }

    public func runningApp(bundleIdentifier: String?, url: URL?) -> RunningApp? {
        applications.first { app in
            if let bundleIdentifier, app.bundleIdentifier == bundleIdentifier { return true }
            if let url, let appURL = app.bundleURL, appURL.standardizedFileURL == url.standardizedFileURL { return true }
            return false
        }
    }

    public func nsRunningApplication(pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }
}
