import AppKit
import Diagnostics
import Foundation

/// Read-only view of the macOS Dock preferences (`com.apple.dock`).
public nonisolated struct SystemDockPreferences: Sendable, Equatable, Codable {
    public enum Orientation: String, Sendable, Codable { case bottom, left, right }

    public var autohide: Bool
    public var orientation: Orientation
    public var tileSize: Double?
    /// Present only when the user (or a tool) customised it.
    public var autohideDelay: Double?

    public static func current() -> SystemDockPreferences {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let autohide = CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false
        let orientationValue = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
        let tile = CFPreferencesCopyAppValue("tilesize" as CFString, domain) as? Double
        let delay = CFPreferencesCopyAppValue("autohide-delay" as CFString, domain) as? Double
        return SystemDockPreferences(
            autohide: autohide,
            orientation: Orientation(rawValue: orientationValue ?? "bottom") ?? .bottom,
            tileSize: tile,
            autohideDelay: delay
        )
    }
}

/// Imports the user's pinned apps from the macOS Dock (read-only, local).
public nonisolated enum SystemDockImporter {
    public struct ImportedApp: Sendable, Equatable {
        public var bundleIdentifier: String?
        public var url: URL
        public var label: String?
    }

    public static func persistentApps() -> [ImportedApp] {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let entries = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] else {
            return []
        }
        return parse(entries: entries)
    }

    /// Parses `persistent-apps` entries. Exposed for tests.
    public static func parse(entries: [[String: Any]]) -> [ImportedApp] {
        var result: [ImportedApp] = []
        for entry in entries {
            guard let tile = entry["tile-data"] as? [String: Any] else { continue }
            let fileData = tile["file-data"] as? [String: Any]
            guard let urlString = fileData?["_CFURLString"] as? String else { continue }
            let url: URL?
            if urlString.hasPrefix("file://") {
                url = URL(string: urlString)
            } else {
                url = URL(fileURLWithPath: urlString)
            }
            guard let url, url.pathExtension == "app" else { continue }
            result.append(ImportedApp(
                bundleIdentifier: tile["bundle-identifier"] as? String,
                url: url,
                label: tile["file-label"] as? String
            ))
        }
        return result
    }
}

/// Changes to the macOS Dock made only through supported, reversible mechanisms and only
/// after explicit consent (Replacement Mode assistant).
///
/// - Auto-hide is set through System Events' documented `dock preferences` scripting suite,
///   which applies immediately without restarting the Dock. Requires Automation consent.
/// - The optional reveal delay uses the `autohide-delay` user default and needs a single
///   Dock relaunch; PulseDock records the previous value so it can always be restored.
public enum SystemDockController {
    public enum ControlError: Error, LocalizedError {
        case scriptFailed(String)
        case automationDenied

        public var errorDescription: String? {
            switch self {
            case let .scriptFailed(message): message
            case .automationDenied: "PulseDock is not allowed to control System Events."
            }
        }
    }

    public static func setAutohide(_ enabled: Bool) throws {
        let source = "tell application id \"com.apple.systemevents\" to set autohide of dock preferences to \(enabled ? "true" : "false")"
        try runAppleScript(source)
    }

    /// Sets (or removes, with `nil`) the reveal delay, then relaunches the Dock once.
    public static func setAutohideDelay(_ delay: Double?) throws {
        let domain = "com.apple.dock" as CFString
        if let delay {
            CFPreferencesSetAppValue("autohide-delay" as CFString, NSNumber(value: delay), domain)
        } else {
            CFPreferencesSetAppValue("autohide-delay" as CFString, nil, domain)
        }
        guard CFPreferencesAppSynchronize(domain) else {
            throw ControlError.scriptFailed("Could not write Dock preferences.")
        }
        relaunchDockOnce()
    }

    /// Asks the Dock to quit; launchd starts it again immediately with the new preferences.
    /// Used once per explicit user action, never in a loop.
    public static func relaunchDockOnce() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
            app.terminate()
        }
    }

    private static func runAppleScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ControlError.scriptFailed("Invalid script")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 { throw ControlError.automationDenied }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"
            PulseLog.dock.error("System Events script failed: \(message, privacy: .public)")
            throw ControlError.scriptFailed(message)
        }
    }
}
