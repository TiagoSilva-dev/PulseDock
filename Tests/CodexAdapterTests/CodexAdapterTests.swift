import AdapterSupport
import AgentBridge
import AgentCore
@testable import CodexAdapter
import Foundation
import Testing

@Suite("Codex: hooks, notify, installers, app-server mapping")
struct CodexAdapterTests {
    /// Payloads shaped after `codex-rs/hooks/schema/generated/*.command.input.schema.json`.
    func hook(_ event: String, _ extra: [String: Any], wall: Int64 = 1_800_000_000_000) -> [AgentEvent] {
        var payload: [String: Any] = [
            "session_id": "thr_123", "transcript_path": NSNull(), "cwd": "/Users/dev/gustfire", "hook_event_name": event,
            "model": "gpt-6.1-sol", "permission_mode": "default",
        ]
        payload.merge(extra) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let envelope = HookEnvelopeBuilder.hookEnvelope(source: .codex, eventHint: nil, rawInput: data, context: nil, options: SanitizerOptions(),
                                                        startWall: wall, startMono: UInt64(wall), bootID: "b", helperPID: 1)!
        return CodexNormalizer.normalize(envelope)
    }

    @Test("Codex hook events normalise, including Bash failures and interrupts")
    func hookNormalization() {
        #expect(hook("SessionStart", ["source": "startup"]).first?.kind == .sessionStarted)
        let prompt = hook("UserPromptSubmit", ["turn_id": "turn_1", "prompt": "secret prompt"])
        #expect(prompt.first?.kind == .promptSubmitted)
        #expect(prompt.first?.turnID == "turn_1")
        #expect(prompt.first?.metadata["model"] == "gpt-6.1-sol")

        let started = hook("PreToolUse", ["turn_id": "turn_1", "tool_name": "Bash", "tool_use_id": "call_1", "tool_input": ["command": ["bash", "-lc", "cargo test"]]])
        #expect(started.first?.tool?.activity == .runningTests)
        #expect(started.first?.tool?.summary == "cargo test")

        let failed = hook("PostToolUse", ["turn_id": "turn_1", "tool_name": "Bash", "tool_use_id": "call_1",
                                          "tool_input": ["command": "cargo test"],
                                          "tool_response": #"{"output":"SECRET","metadata":{"exit_code":101}}"#])
        #expect(failed.first?.kind == .toolFailed)
        #expect(failed.first?.failure?.category == .tests)
        #expect(failed.first?.failure?.code == "101")

        let ok = hook("PostToolUse", ["turn_id": "turn_1", "tool_name": "apply_patch", "tool_use_id": "call_2",
                                      "tool_input": ["command": "*** Begin Patch\n*** Update File: src/main.rs\n+x\n*** End Patch"],
                                      "tool_response": "Success"])
        #expect(ok.first?.kind == .toolCompleted)
        #expect(ok.first?.tool?.filePaths == ["src/main.rs"])

        let plan = hook("PreToolUse", ["turn_id": "turn_1", "tool_name": "update_plan", "tool_use_id": "call_3",
                                       "tool_input": ["plan": [["step": "Write tests", "status": "completed"], ["step": "Fix bug", "status": "in_progress"]]]])
        #expect(plan.map(\.kind) == [.toolStarted, .planUpdated])
        #expect(plan.last?.plan?.completedCount == 1)

        let permission = hook("PermissionRequest", ["turn_id": "turn_1", "tool_name": "Bash", "tool_input": ["command": "rm -rf target", "description": "Needs write access outside the workspace"]])
        #expect(permission.first?.kind == .permissionRequested)
        #expect(permission.first?.attention?.reason == "Needs write access outside the workspace")

        #expect(hook("Interrupt", ["turn_id": "turn_1"]).first?.kind == .turnInterrupted)
        #expect(hook("Stop", ["turn_id": "turn_1", "stop_hook_active": false, "last_assistant_message": "SECRET"]).first?.kind == .turnCompleted)
        #expect(hook("SubagentStart", ["turn_id": "turn_1", "agent_id": "sub_1", "agent_type": "worker"]).first?.kind == .subagentStarted)
    }

    @Test("notify reports turn completion only and drops conversation content")
    func notify() throws {
        let json = #"{"type":"agent-turn-complete","thread-id":"thr_9","turn-id":"turn_3","cwd":"/Users/dev/x","input-messages":["SECRET prompt"],"last-assistant-message":"SECRET answer"}"#
        let envelope = try #require(HookEnvelopeBuilder.notifyEnvelope(argument: json, context: nil, startWall: 1, startMono: 1, bootID: nil, helperPID: 1))
        #expect(!String(decoding: try envelope.encodedLine(), as: UTF8.self).contains("SECRET"))
        let events = CodexNormalizer.normalize(envelope)
        #expect(events.map(\.kind) == [.turnCompleted])
        #expect(events.first?.collection == .codexNotify)
        #expect(AdapterCapabilities.for(.codexNotify).isTurnEndOnly)
    }

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("hooks.json install merges with existing hooks and uninstalls cleanly")
    func hookInstaller() throws {
        let root = try temporaryDirectory()
        let hooksURL = root.appendingPathComponent("hooks.json")
        let original = """
        {
          "description": "team hooks",
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "python3 ~/.codex/hooks/stop.py", "timeout": 30 } ] }
            ]
          }
        }
        """
        try original.write(to: hooksURL, atomically: true, encoding: .utf8)
        let installer = CodexHookInstaller(hooksURL: hooksURL, helperPath: "/x/pulsedock-hook", backupsDirectory: root.appendingPathComponent("b"))
        try installer.apply(installer.planInstall())
        #expect(Set(installer.installedEvents()) == Set(CodexNormalizer.supportedHookEvents))
        let installed = try OrderedJSON.parse(String(contentsOf: hooksURL, encoding: .utf8))
        #expect(installed["hooks"]?["Stop"]?.arrayValue?.count == 2)
        try installer.apply(installer.planUninstall())
        #expect(try OrderedJSON.parse(String(contentsOf: hooksURL, encoding: .utf8)) == (try OrderedJSON.parse(original)))
    }

    @Test("notify install chains the previous command and uninstall restores it")
    func notifyInstaller() throws {
        let root = try temporaryDirectory()
        let config = root.appendingPathComponent("config.toml")
        let original = "model = \"gpt-6.1-sol\"\nnotify = [\"python3\", \"/Users/dev/notify.py\"]\n\n[profiles.fast]\nmodel = \"x\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let chain = root.appendingPathComponent("chain.json")
        let installer = CodexNotifyInstaller(configURL: config, helperPath: "/x/pulsedock-hook", chainURL: chain, backupsDirectory: root.appendingPathComponent("b"))
        let plan = try installer.planInstall()
        #expect(plan.previousCommand == ["python3", "/Users/dev/notify.py"])
        try installer.apply(plan)
        #expect(installer.isInstalled())
        #expect(try String(contentsOf: config, encoding: .utf8).contains("notify = [\"/x/pulsedock-hook\", \"codex-notify\"]"))
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: chain)) == ["python3", "/Users/dev/notify.py"])
        try installer.applyUninstall(installer.planUninstall())
        #expect(try String(contentsOf: config, encoding: .utf8) == original)
    }

    @Test("Multi-line notify arrays are left for manual editing")
    func notifyUnsupportedLayout() throws {
        let root = try temporaryDirectory()
        let config = root.appendingPathComponent("config.toml")
        try "notify = [\n  \"python3\",\n  \"x.py\"\n]\n".write(to: config, atomically: true, encoding: .utf8)
        let installer = CodexNotifyInstaller(configURL: config, helperPath: "/x/pulsedock-hook", chainURL: root.appendingPathComponent("c"), backupsDirectory: root)
        #expect(throws: CodexNotifyInstaller.NotifyError.unsupportedLayout) { try installer.planInstall() }
    }

    @Test("App-server traffic maps to events; approvals carry their decisions")
    func appServerMapping() {
        var mapper = CodexAppServerMapper()
        var events = mapper.events(forNotification: "thread/started", params: ["thread": ["id": "thr_1", "sessionId": "thr_1"]])
        events += mapper.events(forNotification: "turn/started", params: ["threadId": "thr_1", "turn": ["id": "turn_1", "status": "inProgress"]])
        events += mapper.events(forNotification: "item/started", params: ["threadId": "thr_1", "turnId": "turn_1",
                                                                          "item": ["type": "commandExecution", "id": "item_1", "command": "npm test", "cwd": "/x", "status": "inProgress"]])
        events += mapper.events(forServerRequest: "item/commandExecution/requestApproval", requestID: "7",
                                params: ["threadId": "thr_1", "turnId": "turn_1", "itemId": "item_1", "command": "npm test", "reason": "network",
                                         "availableDecisions": ["accept", "decline"]])
        events += mapper.events(forNotification: "serverRequest/resolved", params: ["threadId": "thr_1", "requestId": 7])
        events += mapper.events(forNotification: "item/completed", params: ["threadId": "thr_1", "turnId": "turn_1",
                                                                            "item": ["type": "commandExecution", "id": "item_1", "command": "npm test", "status": "failed", "exitCode": 1, "aggregatedOutput": "SECRET"]])
        events += mapper.events(forNotification: "turn/completed", params: ["threadId": "thr_1", "turn": ["id": "turn_1", "status": "completed"]])

        #expect(events.map(\.kind) == [.sessionStarted, .turnStarted, .toolStarted, .permissionRequested, .approvalResolved, .toolFailed, .turnCompleted])
        let approval = events[3].attention
        #expect(approval?.requestID == "7")
        #expect(approval?.availableDecisions == ["accept", "decline"])
        #expect(events.allSatisfy { $0.collection == .codexAppServer && $0.sessionID == "thr_1" })
        #expect(!events.contains { ($0.tool?.summary ?? "").contains("SECRET") })

        let engine = AgentSessionEngine()
        for event in events.prefix(4) { engine.ingest(event) }
        #expect(engine.sessions.values.first?.state == .waitingUser)
        engine.ingest(events[4])
        #expect(engine.sessions.values.first?.state == .working)
        for event in events.suffix(2) { engine.ingest(event) }
        #expect(engine.sessions.values.first?.state == .completed)
    }
}
