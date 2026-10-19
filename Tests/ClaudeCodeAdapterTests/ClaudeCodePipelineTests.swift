import AgentBridge
import AgentCore
@testable import ClaudeCodeAdapter
import Foundation
import Testing

/// Fixtures are the official hook payload examples (code.claude.com/docs/en/hooks), with
/// marker strings (SECRET_…) placed in every content field that must never survive.
enum Fixtures {
    static func directory() -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/hooks")
    }

    static func all() throws -> [(name: String, data: Data)] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { ($0.deletingPathExtension().lastPathComponent, try Data(contentsOf: $0)) }
    }

    static func envelope(_ data: Data, wall: Int64 = 1_800_000_000_000, mono: UInt64 = 1) -> BridgeEnvelope? {
        HookEnvelopeBuilder.hookEnvelope(
            source: .claudeCode,
            eventHint: nil,
            rawInput: data,
            context: ProcessContext(chain: [], tty: "ttys003", env: ["TERM_PROGRAM": "Apple_Terminal", "CLAUDE_PROJECT_DIR": "/Users/dev/shop"]),
            options: SanitizerOptions(),
            startWall: wall,
            startMono: mono,
            bootID: "boot",
            helperPID: 1
        )
    }
}

@Suite("Claude Code: official payloads through helper sanitizer, normalizer and engine")
struct ClaudeCodePipelineTests {
    @Test("No content field survives the helper's sanitizer")
    func sanitizerRemovesContent() throws {
        for fixture in try Fixtures.all() {
            let envelope = try #require(Fixtures.envelope(fixture.data), "fixture \(fixture.name)")
            let line = String(decoding: try envelope.encodedLine(), as: UTF8.self)
            #expect(!line.contains("SECRET"), "content leaked in \(fixture.name): \(line)")
            #expect(!line.contains("factorial of a number"), "prompt leaked in \(fixture.name)")
            #expect(!line.contains("ruleContent"), "permission suggestions leaked in \(fixture.name)")
            #expect(!line.contains("from __future__"), "tool output leaked in \(fixture.name)")
        }
    }

    @Test("Every fixture maps to the documented semantic event")
    func normalization() throws {
        let expected: [String: AgentEventKind] = [
            "01-SessionStart": .sessionStarted, "02-UserPromptSubmit": .promptSubmitted, "03-PreToolUse-Read": .toolStarted,
            "04-PostToolUse-Read": .toolCompleted, "05-PreToolUse-Write": .toolStarted, "06-PostToolUse-Write": .toolCompleted,
            "07-PreToolUse-Bash": .toolStarted, "08-PostToolUseFailure-Bash": .toolFailed, "09-PreToolUse-Bash-rm": .toolStarted,
            "10-PermissionRequest": .permissionRequested, "11-Notification-permission": .attentionNeeded,
            "12-PostToolUse-Bash-rm": .toolCompleted, "13-PostToolBatch": .toolBatchCompleted, "14-SubagentStart": .subagentStarted,
            "15-PreToolUse-Glob-in-subagent": .toolStarted, "16-PostToolUse-Glob-in-subagent": .toolCompleted,
            "17-SubagentStop": .subagentStopped, "18-TaskCreated": .taskCreated, "19-TaskCompleted": .taskCompleted,
            "20-Stop": .turnCompleted, "21-Notification-idle": .idleReminder, "22-StopFailure": .turnFailed, "23-SessionEnd": .sessionEnded,
        ]
        for fixture in try Fixtures.all() {
            let envelope = try #require(Fixtures.envelope(fixture.data))
            let events = ClaudeCodeNormalizer.normalize(envelope)
            #expect(events.first?.kind == expected[fixture.name], "\(fixture.name)")
            #expect(events.first?.collection == .claudeHook)
            #expect(events.first?.sessionID == "abc123")
            #expect(events.first?.origin?.projectRoot == "/Users/dev/shop")
        }
    }

    @Test("Tool details come from concrete fields")
    func toolDetails() throws {
        let fixtures = Dictionary(uniqueKeysWithValues: try Fixtures.all().map { ($0.name, $0.data) })
        let test = ClaudeCodeNormalizer.normalize(try #require(Fixtures.envelope(fixtures["07-PreToolUse-Bash"]!))).first
        #expect(test?.tool?.activity == .runningTests)
        #expect(test?.tool?.summary == "npm test")
        #expect(test?.turnID == "550e8400-e29b-41d4-a716-446655440000")

        let failure = ClaudeCodeNormalizer.normalize(try #require(Fixtures.envelope(fixtures["08-PostToolUseFailure-Bash"]!))).first
        #expect(failure?.failure?.category == .tests)
        #expect(failure?.failure?.code == "1")
        #expect(failure?.failure?.summary == "Exit code 1")

        let write = ClaudeCodeNormalizer.normalize(try #require(Fixtures.envelope(fixtures["05-PreToolUse-Write"]!))).first
        #expect(write?.tool?.activity == .editingCode)
        #expect(write?.tool?.summary == "factorial.py")

        let glob = ClaudeCodeNormalizer.normalize(try #require(Fixtures.envelope(fixtures["15-PreToolUse-Glob-in-subagent"]!))).first
        #expect(glob?.subagentID == "agent-abc123")

        let stop = ClaudeCodeNormalizer.normalize(try #require(Fixtures.envelope(fixtures["20-Stop"]!))).first
        #expect(stop?.metadata["background_tasks"] == "1")

        let apiFailure = ClaudeCodeNormalizer.normalize(try #require(Fixtures.envelope(fixtures["22-StopFailure"]!))).first
        #expect(apiFailure?.failure?.code == "rate_limit")
    }

    @Test("Replaying the fixture session yields the expected states at each step")
    func endToEndSession() throws {
        let engine = AgentSessionEngine()
        var states: [String: SessionState] = [:]
        for (index, fixture) in try Fixtures.all().enumerated() {
            let envelope = try #require(Fixtures.envelope(fixture.data, wall: 1_800_000_000_000 + Int64(index) * 1000, mono: UInt64(index + 1) * 1_000_000_000))
            engine.ingest(ClaudeCodeNormalizer.normalize(envelope, receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))))
            states[fixture.name] = engine.only()?.state
        }
        #expect(states["01-SessionStart"] == .idle)
        #expect(states["02-UserPromptSubmit"] == .working)
        #expect(states["08-PostToolUseFailure-Bash"] == .working)
        #expect(states["10-PermissionRequest"] == .waitingUser)
        #expect(states["11-Notification-permission"] == .waitingUser)
        #expect(states["12-PostToolUse-Bash-rm"] == .working)
        #expect(states["14-SubagentStart"] == .working)
        #expect(states["20-Stop"] == .completed)
        #expect(states["21-Notification-idle"] == .completed)
        #expect(states["22-StopFailure"] == .failed)

        let session = try #require(engine.only())
        #expect(session.lifecycle == .ended)
        #expect(session.subagents["agent-abc123"]?.status == .completed)
        #expect(session.tasks.first?.status == .completed)
        #expect(session.origin?.tty == "ttys003")
    }
}

extension AgentSessionEngine {
    func only() -> AgentSession? { sessions.values.first }
}
