import AgentBridge
import AgentCore
import AppKit
import Diagnostics
import DockCore
import Foundation

/// Returns to the place where a session runs, in order of certainty:
/// 1. the exact terminal tab (Terminal or iTerm2, matched by the session's TTY);
/// 2. the app that hosts the session (from the session's own process chain);
/// 3. the project, opened in that host app when it is an editor;
/// 4. the project folder in Finder.
/// It never brings forward a terminal that was not identified from the session itself.
enum SmartReturn {
    enum Outcome: Equatable {
        case selectedTab(String)
        case activatedHost(String)
        case openedProject
        case revealedFolder
        case unavailable
    }

    static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.exafunction.windsurf", "com.jetbrains.intellij", "com.google.antigravity",
    ]

    static func returnTo(_ session: AgentSession, project: ProjectInfo?, completion: @escaping @MainActor (Outcome) -> Void) {
        let origin = session.origin
        let hostID = origin?.hostAppBundleID
        let hostName = hostID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map(NSWorkspaceLookup.displayName(for:)) ?? origin?.terminalProgram ?? ""

        if let tty = origin?.tty, let hostID, let script = tabScript(bundleID: hostID, tty: "/dev/\(tty)") {
            AppleScriptRunner.execute(script, timeout: 6) { result in
                if result.error == nil, result.output == "ok" {
                    completion(.selectedTab(hostName))
                } else {
                    if result.isPermissionDenied {
                        DiagnosticsRecorder.shared.record(.warning, "smart-return", "automation denied for \(hostID)")
                    }
                    completion(activateHost(session: session, project: project, hostName: hostName))
                }
            }
            return
        }
        completion(activateHost(session: session, project: project, hostName: hostName))
    }

    @MainActor
    private static func activateHost(session: AgentSession, project: ProjectInfo?, hostName: String) -> Outcome {
        let origin = session.origin
        let projectURL = (project?.rootPath ?? session.projectPath).map { URL(fileURLWithPath: $0, isDirectory: true) }

        // The host must be the very process that ran the agent (still alive), or the app
        // whose bundle the hook reported; nothing is guessed.
        var hostURL: URL?
        if let pid = origin?.hostAppPID, let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL,
           origin?.hostAppPath.map({ url.path == $0 }) ?? true {
            hostURL = url
        } else if let path = origin?.hostAppPath, FileManager.default.fileExists(atPath: path) {
            hostURL = URL(fileURLWithPath: path)
        } else if let id = origin?.hostAppBundleID {
            hostURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }

        if let hostURL {
            let bundleID = Bundle(url: hostURL)?.bundleIdentifier ?? origin?.hostAppBundleID ?? ""
            if editors.contains(bundleID), let projectURL {
                AppLauncher.open([projectURL], withApplicationAt: hostURL)
                return .openedProject
            }
            AppLauncher.openOrActivate(applicationAt: hostURL)
            return .activatedHost(hostName)
        }
        if let projectURL, FileManager.default.fileExists(atPath: projectURL.path) {
            AppLauncher.open(projectURL)
            return .revealedFolder
        }
        return .unavailable
    }

    /// AppleScript that selects the tab whose TTY matches, for terminals with a documented
    /// scripting dictionary. Returns "ok" when found.
    static func tabScript(bundleID: String, tty: String) -> String? {
        let quoted = AppleScriptRunner.quoted(tty)
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(quoted) then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(quoted) then
                                select w
                                select t
                                select s
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        default:
            return nil
        }
    }
}
