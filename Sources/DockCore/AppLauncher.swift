import AppKit
import Diagnostics
import Foundation

/// Launching, switching and managing applications through public NSWorkspace APIs.
public enum AppLauncher {
    /// Opens the app, or brings it forward if it is already running. Going through
    /// LaunchServices (instead of `NSRunningApplication.activate`) matches Dock behaviour:
    /// a running app with no windows receives a "reopen" event and shows a new window, and
    /// activation is permitted even though PulseDock itself is never the active app.
    public static func openOrActivate(applicationAt url: URL, newInstance: Bool = false, completion: (@MainActor (Error?) -> Void)? = nil) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = newInstance
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                PulseLog.dock.error("Failed to open application: \(error.localizedDescription, privacy: .public)")
            }
            if let completion {
                Task { @MainActor in completion(error) }
            }
        }
    }

    /// Opens files with a specific application (drop on icon).
    public static func open(_ files: [URL], withApplicationAt url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration) { _, error in
            if let error {
                PulseLog.dock.error("Failed to open files with application: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func hide(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.hide()
    }

    public static func unhide(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.unhide()
    }

    /// Hides every regular application except the given one ("Hide Others").
    public static func hideOthers(except pid: pid_t) {
        let own = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.processIdentifier != pid && app.processIdentifier != own {
            app.hide()
        }
    }

    public static func quit(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    public static func forceQuit(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.forceTerminate()
    }

    /// Moves items to the Trash through the Finder-compatible public API.
    public static func moveToTrash(_ urls: [URL], completion: (@MainActor (Int) -> Void)? = nil) {
        NSWorkspace.shared.recycle(urls) { recycled, error in
            if let error {
                PulseLog.dock.error("Move to Trash failed: \(error.localizedDescription, privacy: .public)")
            }
            let count = recycled.count
            if let completion {
                Task { @MainActor in completion(count) }
            }
        }
    }

    public static var trashURL: URL {
        (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
    }

    public static func openTrash() {
        NSWorkspace.shared.open(trashURL)
    }
}
