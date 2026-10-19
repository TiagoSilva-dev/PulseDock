@testable import AgentCore
import Foundation
import Testing

@Suite("Session state machine")
struct SessionReducerTests {
    @Test("A finished turn is 'completed' for the turn only, never a task result")
    func turnLifecycle() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.sessionStarted, at: 0, turn: nil, metadata: ["source": "startup"]))
        #expect(engine.only()?.state == .idle)
        engine.ingest(f.make(.promptSubmitted, at: 1))
        #expect(engine.only()?.state == .working)
        #expect(engine.only()?.activity?.kind == .thinking)
        engine.ingest(f.make(.toolStarted, at: 2, tool: EventFactory.bash("swift test", id: "t1")))
        #expect(engine.only()?.activity?.kind == .runningTests)
        engine.ingest(f.make(.toolCompleted, at: 9, tool: EventFactory.bash("swift test", id: "t1")))
        #expect(engine.only()?.activity?.kind == .thinking)
        engine.ingest(f.make(.turnCompleted, at: 10, metadata: ["background_tasks": "0"]))

        let session = try! #require(engine.only())
        #expect(session.state == .completed)
        #expect(session.currentTurn == nil)
        #expect(session.lastTurn?.state == .completed)
        #expect(session.lastTurn?.toolCount == 1)
        #expect(session.tasks.isEmpty)
        #expect(session.toolsInFlight.isEmpty)
    }

    @Test("Permission request waits for the user and clears on the matching tool result")
    func permissionResolvedByToolResult() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        let tool = EventFactory.bash("rm -rf build", id: "t1", fingerprint: "fp-rm")
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.toolStarted, at: 1, tool: tool))
        var permissionTool = tool
        permissionTool.useID = nil // PermissionRequest has no tool_use_id
        engine.ingest(f.make(.permissionRequested, at: 1.1, tool: permissionTool,
                             attention: AttentionInfo(kind: .permission, toolName: "Bash", summary: "rm -rf build")))
        #expect(engine.only()?.state == .waitingUser)
        #expect(engine.only()?.pendingAttention?.info.kind == .permission)
        engine.ingest(f.make(.toolCompleted, at: 5, tool: tool))
        #expect(engine.only()?.state == .working)
        #expect(engine.only()?.pendingAttentions.isEmpty == true)
    }

    @Test("A parallel tool finishing does not hide a pending permission")
    func parallelToolKeepsPermission() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.toolStarted, at: 1, tool: EventFactory.read("a.swift", id: "r1")))
        let bash = EventFactory.bash("git push", id: "b1", fingerprint: "fp-push")
        engine.ingest(f.make(.toolStarted, at: 1, tool: bash))
        var permissionTool = bash
        permissionTool.useID = nil
        engine.ingest(f.make(.permissionRequested, at: 1.2, tool: permissionTool, attention: AttentionInfo(kind: .permission, toolName: "Bash")))
        engine.ingest(f.make(.toolCompleted, at: 1.5, tool: EventFactory.read("a.swift", id: "r1")))
        #expect(engine.only()?.state == .waitingUser)
    }

    @Test("A denied permission (no tool result) clears when the batch resolves")
    func deniedPermissionClearsOnBatch() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        let bash = EventFactory.bash("curl example.com", id: "b1")
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.toolStarted, at: 1, tool: bash))
        engine.ingest(f.make(.permissionRequested, at: 1.1, tool: bash, attention: AttentionInfo(kind: .permission, toolName: "Bash")))
        engine.ingest(f.make(.toolBatchCompleted, at: 8))
        let session = try! #require(engine.only())
        #expect(session.state == .working)
        #expect(session.toolsInFlight.isEmpty)
        #expect(session.pendingAttentions.isEmpty)
    }

    @Test("A new prompt while a turn never reported completion infers an interrupted turn")
    func supersededTurnIsInterrupted() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0, turn: "p1"))
        engine.ingest(f.make(.toolStarted, at: 1, turn: "p1", tool: EventFactory.read("a", id: "r1")))
        engine.ingest(f.make(.promptSubmitted, at: 30, turn: "p2"))
        let session = try! #require(engine.only())
        #expect(session.lastTurn?.id == "p1")
        #expect(session.lastTurn?.state == .interrupted)
        #expect(session.lastTurn?.confidence == .inferred)
        #expect(session.currentTurn?.id == "p2")
        #expect(session.state == .working)
    }

    @Test("idle_prompt after a turn without Stop means the turn was interrupted")
    func idleReminderInfersInterrupt() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.idleReminder, at: 90))
        let session = try! #require(engine.only())
        #expect(session.state == .interrupted)
        #expect(session.stateConfidence == .inferred)
        #expect(session.lastTurn?.state == .interrupted)
    }

    @Test("idle_prompt after a completed turn keeps 'completed'")
    func idleReminderAfterCompletion() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.turnCompleted, at: 5))
        engine.ingest(f.make(.idleReminder, at: 65))
        #expect(engine.only()?.state == .completed)
        #expect(engine.only()?.awaitingInputSince != nil)
    }

    @Test("API failure ends the turn as failed")
    func stopFailure() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.turnFailed, at: 3, failure: FailureInfo(category: .api, code: "rate_limit")))
        let session = try! #require(engine.only())
        #expect(session.state == .failed)
        #expect(session.recentFailure?.info.code == "rate_limit")
        #expect(session.lastTurn?.state == .failed)
    }

    @Test("A failing test command is a tool failure; the session keeps working")
    func toolFailureKeepsWorking() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        let tool = EventFactory.bash("npm test", id: "t1")
        engine.ingest(f.make(.toolStarted, at: 1, tool: tool))
        engine.ingest(f.make(.toolFailed, at: 4, tool: tool, failure: FailureInfo(category: .tests, code: "1")))
        let session = try! #require(engine.only())
        #expect(session.state == .working)
        #expect(session.recentFailure?.info.category == .tests)
        #expect(session.currentTurn?.failedToolCount == 1)
    }

    @Test("Subagents form a hierarchy and attribute their tools")
    func subagents() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.subagentStarted, at: 1, subagent: "a1", subagentType: "Explore"))
        engine.ingest(f.make(.subagentStarted, at: 1.1, subagent: "a2", subagentType: "Plan"))
        engine.ingest(f.make(.toolStarted, at: 2, tool: EventFactory.read("x.swift", id: "r1"), subagent: "a1"))
        var session = try! #require(engine.only())
        #expect(session.runningSubagents.count == 2)
        #expect(session.subagents["a1"]?.toolCount == 1)
        #expect(session.activity?.subagentID == "a1")
        engine.ingest(f.make(.subagentStopped, at: 5, subagent: "a1", subagentType: "Explore"))
        session = try! #require(engine.only())
        #expect(session.subagents["a1"]?.status == .completed)
        #expect(session.toolsInFlight.isEmpty)
        // Internal agents stop with an empty type and no start: no record is created.
        engine.ingest(f.make(.subagentStopped, at: 6, subagent: "internal", subagentType: ""))
        #expect(engine.only()?.subagents["internal"] == nil)
    }

    @Test("Ending a session mid-turn marks the turn interrupted (inferred)")
    func sessionEndDuringTurn() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.sessionEnded, at: 5, metadata: ["reason": "prompt_input_exit"]))
        let session = try! #require(engine.only())
        #expect(session.lifecycle == .ended)
        #expect(session.state == .interrupted)
        #expect(session.endReason == "prompt_input_exit")
    }

    @Test("Compaction mid-turn does not reset the turn")
    func compactionKeepsTurn() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.compactionStarted, at: 1))
        engine.ingest(f.make(.sessionStarted, at: 2, metadata: ["source": "compact"]))
        engine.ingest(f.make(.compactionFinished, at: 3))
        let session = try! #require(engine.only())
        #expect(session.state == .working)
        #expect(session.currentTurn != nil)
    }

    @Test("The same turn reported by hooks and notify is counted once")
    func duplicateTurnCompletion() {
        var f = EventFactory(provider: .codex)
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0, turn: "t1", collection: .codexHook))
        engine.ingest(f.make(.turnCompleted, at: 5, turn: "t1", collection: .codexHook))
        engine.ingest(f.make(.turnCompleted, at: 5.4, turn: "t1", collection: .codexNotify))
        #expect(engine.only()?.turnCount == 1)
        #expect(engine.only()?.state == .completed)
    }

    @Test("Tasks give a verifiable total; without them progress is indeterminate")
    func progress() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        #expect(ProgressEvaluator.progress(for: engine.only()!, effectiveState: .working) == .indeterminate)
        for index in 1...4 {
            engine.ingest(f.make(.taskCreated, at: Double(index), task: TaskInfo(id: "t\(index)", subject: "Step \(index)", status: .pending)))
        }
        engine.ingest(f.make(.taskCompleted, at: 6, task: TaskInfo(id: "t1", subject: nil, status: .completed)))
        engine.ingest(f.make(.taskCompleted, at: 7, task: TaskInfo(id: "t2", subject: nil, status: .completed)))
        let progress = ProgressEvaluator.progress(for: engine.only()!, effectiveState: .working)
        #expect(progress == .determinate(completed: 2, total: 4, source: "tasks"))
        #expect(progress.fraction == 0.5)
    }
}
