import AdapterSupport
@testable import ClaudeCodeAdapter
import Foundation
import Testing

@Suite("Claude Code status line installer: chains the user's own status line and restores it")
struct ClaudeStatusLineInstallerTests {
    let helper = "/Users/dev/Library/Application Support/PulseDock/bin/pulsedock-hook"

    func makeInstaller() throws -> (ClaudeStatusLineInstaller, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulsedock-statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installer = ClaudeStatusLineInstaller(
            settingsURL: root.appendingPathComponent("settings.json"),
            helperPath: helper,
            backupsDirectory: root.appendingPathComponent("backups"),
            chainURL: root.appendingPathComponent("chain.json")
        )
        return (installer, installer.settingsURL)
    }

    @Test("Without a status line: adds PulseDock's, keeps other keys, removal deletes it")
    func freshInstall() throws {
        let (installer, settings) = try makeInstaller()
        let original = "{\n  \"model\": \"opus\",\n  \"hooks\": {}\n}\n"
        try original.write(to: settings, atomically: true, encoding: .utf8)
        #expect(installer.status() == .notInstalled(hasOwn: false))

        let plan = try installer.planInstall()
        #expect(plan.chained == nil)
        try installer.apply(plan)
        let root = try OrderedJSON.parse(String(contentsOf: settings, encoding: .utf8))
        #expect(root.objectPairs?.map(\.0) == ["model", "hooks", "statusLine"])
        #expect(root["statusLine"]?["command"]?.stringValue?.hasSuffix("claude-statusline || exit 0") == true)
        #expect(installer.status() == .installed(chained: false))
        // Idempotent.
        #expect(try installer.planInstall().change.isNoOp)

        try installer.apply(try installer.planUninstall())
        #expect(try String(contentsOf: settings, encoding: .utf8) == original)
        #expect(installer.status() == .notInstalled(hasOwn: false))
    }

    @Test("An existing status line keeps running behind PulseDock's and comes back exactly")
    func chainsAndRestores() throws {
        let (installer, settings) = try makeInstaller()
        let original = """
        {
          "statusLine": {
            "type": "command",
            "command": "~/.claude/statusline.sh # mine",
            "padding": 2,
            "refreshInterval": 5
          },
          "theme": "dark"
        }

        """
        try original.write(to: settings, atomically: true, encoding: .utf8)
        #expect(installer.status() == .notInstalled(hasOwn: true))

        let plan = try installer.planInstall()
        #expect(plan.change.preservedForeignHandlers == 1)
        try installer.apply(plan)
        let root = try OrderedJSON.parse(String(contentsOf: settings, encoding: .utf8))
        let statusLine = try #require(root["statusLine"])
        #expect(statusLine.objectPairs?.map(\.0) == ["type", "padding", "refreshInterval", "command"])
        let command = try #require(statusLine["command"]?.stringValue)
        // The user's command is the shell fallback (a trailing comment cannot swallow the ")").
        #expect(command.hasSuffix(" || ( ~/.claude/statusline.sh # mine\n)"))
        #expect(ClaudeStatusLineInstaller.embeddedFallback(in: command) == "~/.claude/statusline.sh # mine")
        #expect(FileManager.default.fileExists(atPath: installer.chainURL.path))
        #expect(installer.status() == .installed(chained: true))

        try installer.apply(try installer.planUninstall())
        #expect(try OrderedJSON.parse(String(contentsOf: settings, encoding: .utf8)) == OrderedJSON.parse(original))
        #expect(!FileManager.default.fileExists(atPath: installer.chainURL.path))
    }

    @Test("Removal still restores the user's command when the chain file was lost")
    func restoresFromFallback() throws {
        let (installer, settings) = try makeInstaller()
        try "{\"statusLine\": {\"type\": \"command\", \"command\": \"echo hi\"}}\n".write(to: settings, atomically: true, encoding: .utf8)
        try installer.apply(try installer.planInstall())
        try FileManager.default.removeItem(at: installer.chainURL)
        try installer.apply(try installer.planUninstall())
        let root = try OrderedJSON.parse(String(contentsOf: settings, encoding: .utf8))
        #expect(root["statusLine"]?["command"]?.stringValue == "echo hi")
    }

    @Test("A file changed after the preview is never overwritten")
    func refusesConcurrentChange() throws {
        let (installer, settings) = try makeInstaller()
        try "{}\n".write(to: settings, atomically: true, encoding: .utf8)
        let plan = try installer.planInstall()
        try "{\"theme\": \"light\"}\n".write(to: settings, atomically: true, encoding: .utf8)
        #expect(throws: ConfigEditError.changedSinceReview) { try installer.apply(plan) }
    }
}
