import AgentBridge
import Foundation

/// Locates the Claude Code CLI and reports its version without depending on the GUI's PATH.
public struct ClaudeCodeInstallation: Sendable, Equatable {
    public var executablePath: String?
    public var version: String?
    public var settingsURL: URL
    public var settingsExists: Bool

    public var isInstalled: Bool { executablePath != nil }
}

public enum ClaudeCodeDetector {
    public static var configDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
    }

    public static var defaultSettingsURL: URL { configDirectory.appendingPathComponent("settings.json") }
    public static var sessionsDirectory: URL { configDirectory.appendingPathComponent("sessions", isDirectory: true) }

    public static let candidatePaths: [String] = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.npm-global/bin/claude",
        "~/.bun/bin/claude",
    ]

    public static func detect(allowSpawningVersionCheck: Bool = true) -> ClaudeCodeInstallation {
        let fileManager = FileManager.default
        let executable = candidatePaths
            .map { ($0 as NSString).expandingTildeInPath }
            .first { fileManager.isExecutableFile(atPath: $0) }
        var version: String?
        if let executable {
            version = versionFromLayout(executable) ?? (allowSpawningVersionCheck ? versionFromCommand(executable) : nil)
        }
        let settings = defaultSettingsURL
        return ClaudeCodeInstallation(
            executablePath: executable,
            version: version,
            settingsURL: settings,
            settingsExists: fileManager.fileExists(atPath: settings.path)
        )
    }

    /// Native installs symlink `claude` to `…/versions/<version>`; npm installs ship a
    /// `package.json` next to the CLI.
    static func versionFromLayout(_ executable: String) -> String? {
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: executable))
            .map { $0.hasPrefix("/") ? $0 : ((executable as NSString).deletingLastPathComponent as NSString).appendingPathComponent($0) }
            ?? executable
        let name = (resolved as NSString).lastPathComponent
        if SemanticVersion(name) != nil, name.first?.isNumber == true { return name }
        var directory = (resolved as NSString).deletingLastPathComponent
        for _ in 0..<4 {
            let package = (directory as NSString).appendingPathComponent("package.json")
            if let data = FileManager.default.contents(atPath: package),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (object["name"] as? String)?.contains("claude-code") == true,
               let version = object["version"] as? String {
                return version
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func versionFromCommand(_ executable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: " ").first.map(String.init).flatMap { SemanticVersion($0) != nil ? $0 : nil }
    }
}
