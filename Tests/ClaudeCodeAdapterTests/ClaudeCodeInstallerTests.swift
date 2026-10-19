import AdapterSupport
@testable import ClaudeCodeAdapter
import Foundation
import Testing

@Suite("Claude Code hook installer: reversible, preserves foreign configuration")
struct ClaudeCodeInstallerTests {
    let existingSettings = """
    {
      "model": "opus",
      "theme": "dark",
      "enabledPlugins": {
        "typesafe@typesafe-ai": true
      },
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "/usr/local/bin/my-policy.sh"
              }
            ]
          }
        ]
      },
      "permissions": {
        "allow": ["Bash(npm test)"]
      }
    }

    """

    func makeInstaller() throws -> (ClaudeCodeHookInstaller, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulsedock-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("settings.json")
        let installer = ClaudeCodeHookInstaller(
            settingsURL: settings,
            helperPath: "/Users/dev/Library/Application Support/PulseDock/bin/pulsedock-hook",
            backupsDirectory: root.appendingPathComponent("backups")
        )
        return (installer, settings)
    }

    @Test("Install keeps every foreign key and handler, in order")
    func installPreservesForeignConfiguration() throws {
        let (installer, settings) = try makeInstaller()
        try existingSettings.write(to: settings, atomically: true, encoding: .utf8)

        let plan = try installer.planInstall(version: "2.1.302")
        #expect(plan.preservedForeignHandlers == 1)
        #expect(plan.addedEvents.count == ClaudeCodeHookInstaller.modernEvents.count)
        let backup = try installer.apply(plan)
        #expect(backup != nil)

        let root = try OrderedJSON.parse(String(contentsOf: settings, encoding: .utf8))
        #expect(root.objectPairs?.map(\.0) == ["model", "theme", "enabledPlugins", "hooks", "permissions"])
        let preToolUse = try #require(root["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(preToolUse.count == 2)
        #expect(preToolUse[0]["hooks"]?.arrayValue?.first?["command"]?.stringValue == "/usr/local/bin/my-policy.sh")
        let ours = try #require(preToolUse[1]["hooks"]?.arrayValue?.first?["command"]?.stringValue)
        #expect(ours.contains("'/Users/dev/Library/Application Support/PulseDock/bin/pulsedock-hook' claude-code PreToolUse"))
        #expect(ours.hasPrefix("[ -x "))
        #expect(installer.status(version: "2.1.302") == .installed(events: ClaudeCodeHookInstaller.modernEvents))
    }

    @Test("Install is idempotent and uninstall restores the original content")
    func idempotentAndReversible() throws {
        let (installer, settings) = try makeInstaller()
        try existingSettings.write(to: settings, atomically: true, encoding: .utf8)
        try installer.apply(installer.planInstall(version: "2.1.302"))
        let afterFirst = try String(contentsOf: settings, encoding: .utf8)
        let second = try installer.planInstall(version: "2.1.302")
        #expect(second.isNoOp)
        #expect(second.removedHandlers == ClaudeCodeHookInstaller.modernEvents.count)
        #expect(try String(contentsOf: settings, encoding: .utf8) == afterFirst)

        let uninstall = try installer.planUninstall()
        #expect(uninstall.removedHandlers == ClaudeCodeHookInstaller.modernEvents.count)
        try installer.apply(uninstall)
        let restored = try OrderedJSON.parse(String(contentsOf: settings, encoding: .utf8))
        #expect(restored == (try OrderedJSON.parse(existingSettings)))
        #expect(installer.status(version: "2.1.302") == .notInstalled)
    }

    @Test("A file without hooks gets the hooks key back out on uninstall")
    func uninstallFromEmptyFile() throws {
        let (installer, settings) = try makeInstaller()
        try "{\n  \"theme\": \"dark\"\n}\n".write(to: settings, atomically: true, encoding: .utf8)
        try installer.apply(installer.planInstall(version: nil))
        try installer.apply(installer.planUninstall())
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{\n  \"theme\": \"dark\"\n}\n")
    }

    @Test("Changes made after the preview are never overwritten")
    func refusesStalePlan() throws {
        let (installer, settings) = try makeInstaller()
        try existingSettings.write(to: settings, atomically: true, encoding: .utf8)
        let plan = try installer.planInstall(version: "2.1.302")
        try (existingSettings + " ").write(to: settings, atomically: true, encoding: .utf8)
        #expect(throws: ConfigEditError.changedSinceReview) { try installer.apply(plan) }
    }

    @Test("Invalid JSON is reported, not rewritten")
    func refusesInvalidJSON() throws {
        let (installer, settings) = try makeInstaller()
        try "{ \"theme\": ".write(to: settings, atomically: true, encoding: .utf8)
        #expect(throws: ConfigEditError.self) { try installer.planInstall(version: nil) }
        if case .unreadable = installer.status(version: nil) {} else { Issue.record("expected unreadable status") }
    }

    @Test("Hook command quoting survives apostrophes in paths")
    func commandQuoting() {
        let installer = ClaudeCodeHookInstaller(settingsURL: URL(fileURLWithPath: "/tmp/x.json"), helperPath: "/Users/o'neil/bin/pulsedock-hook", backupsDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(installer.command(for: "Stop") == "[ -x '/Users/o'\\''neil/bin/pulsedock-hook' ] && exec '/Users/o'\\''neil/bin/pulsedock-hook' claude-code Stop || exit 0")
    }

    @Test("Older versions get the conservative event set")
    func versionGating() {
        #expect(ClaudeCodeHookInstaller.events(forVersion: "2.0.15") == ClaudeCodeHookInstaller.legacyEvents)
        #expect(ClaudeCodeHookInstaller.events(forVersion: "2.1.302 (Claude Code)") == ClaudeCodeHookInstaller.modernEvents)
    }

    @Test("Session registry entries parse without reading key files")
    func registryParsing() throws {
        let json = #"{"pid":6067,"sessionId":"8c5135da","cwd":"/Users/dev/shop","startedAt":1792352059486,"kind":"interactive","entrypoint":"cli","name":"shop-main","status":"busy","updatedAt":1792352327658}"#
        let entry = try #require(ClaudeSessionRegistry.parse(Data(json.utf8)))
        #expect(entry.pid == 6067)
        #expect(entry.sessionID == "8c5135da")
        #expect(entry.name == "shop-main")
        let event = ClaudeSessionRegistry.discoveryEvent(for: entry)
        #expect(event.kind == .sessionDiscovered)
        #expect(event.confidence == .inferred)
        #expect(event.metadata["session_title"] == "shop-main")
    }
}
