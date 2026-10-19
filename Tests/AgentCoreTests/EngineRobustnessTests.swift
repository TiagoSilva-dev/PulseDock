@testable import AgentCore
import Foundation
import Testing

@Suite("Engine robustness: duplicates, ordering, staleness, reconciliation")
struct EngineRobustnessTests {
    func scenario() -> [AgentEvent] {
        var f = EventFactory()
        let bash = EventFactory.bash("swift build", id: "b1", fingerprint: "fp-build")
        var permission = bash
        permission.useID = nil
        return [
            f.make(.sessionStarted, at: 0, turn: nil, metadata: ["source": "startup"]),
            f.make(.promptSubmitted, at: 1),
            f.make(.toolStarted, at: 2, tool: EventFactory.read("a.swift", id: "r1")),
            f.make(.toolCompleted, at: 2.5, tool: EventFactory.read("a.swift", id: "r1")),
            f.make(.subagentStarted, at: 3, subagent: "x", subagentType: "Explore"),
            f.make(.toolStarted, at: 4, tool: bash),
            f.make(.permissionRequested, at: 4.1, tool: permission, attention: AttentionInfo(kind: .permission, toolName: "Bash")),
            f.make(.toolCompleted, at: 9, tool: bash),
            f.make(.subagentStopped, at: 10, subagent: "x", subagentType: "Explore"),
            f.make(.taskCreated, at: 11, task: TaskInfo(id: "t1", subject: "A", status: .pending)),
            f.make(.taskCompleted, at: 12, task: TaskInfo(id: "t1", subject: "A", status: .completed)),
            f.make(.turnCompleted, at: 13),
        ]
    }

    @Test("Arrival order does not change the resulting session")
    func outOfOrderDeliveryIsDeterministic() {
        let events = scenario()
        let ordered = AgentSessionEngine()
        events.forEach { ordered.ingest($0) }
        let expected = try! #require(ordered.only())

        var generator = SeededGenerator(seed: 42)
        for _ in 0..<25 {
            let shuffled = AgentSessionEngine()
            for event in events.shuffled(using: &generator) { shuffled.ingest(event) }
            let session = try! #require(shuffled.only())
            #expect(session.state == expected.state)
            #expect(session.lastTurn?.state == expected.lastTurn?.state)
            #expect(session.turnCount == expected.turnCount)
            #expect(session.tasks.map(\.status) == expected.tasks.map(\.status))
            #expect(session.subagents == expected.subagents)
            #expect(session.pendingAttentions.isEmpty)
        }
    }

    @Test("Repeated ids and near-simultaneous identical events are ignored")
    func duplicates() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        let prompt = f.make(.promptSubmitted, at: 0)
        #expect(engine.ingest(prompt) == .applied)
        #expect(engine.ingest(prompt) == .duplicate)
        // Same content from a second registration of the hook, a few ms later, other id.
        var twin = prompt
        twin.id = "twin"
        twin.receivedAt = prompt.receivedAt.addingTimeInterval(0.004)
        twin.order.monotonicNanos = (prompt.order.monotonicNanos ?? 0) + 4_000_000
        twin.order.wallMillis += 4
        #expect(engine.ingest(twin) == .duplicate)
        #expect(engine.only()?.turnCount == 1)
    }

    @Test("Silence is never idleness: working becomes stale only after the quiet limit")
    func staleness() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        let session = try! #require(engine.only())
        let policy = StalenessPolicy.standard
        let start = f.start
        #expect(policy.evaluate(session, now: start.addingTimeInterval(5 * 60), processAlive: true).state == .working)
        let late = policy.evaluate(session, now: start.addingTimeInterval(11 * 60), processAlive: true)
        #expect(late.state == .stale)
        #expect(late.confidence == .inferred)
        #expect(policy.evaluate(session, now: start.addingTimeInterval(60), processAlive: false).state == .stale)

        engine.ingest(f.make(.toolStarted, at: 1, tool: EventFactory.bash("swift test", id: "t")))
        let withTool = try! #require(engine.only())
        #expect(policy.evaluate(withTool, now: start.addingTimeInterval(30 * 60), processAlive: true).state == .working)
        #expect(policy.evaluate(withTool, now: start.addingTimeInterval(50 * 60), processAlive: true).state == .stale)
    }

    @Test("A permission prompt waits indefinitely while the process is alive")
    func waitingDoesNotGoStaleWhileAlive() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.permissionRequested, at: 1, tool: EventFactory.bash("ls", id: "x"), attention: AttentionInfo(kind: .permission)))
        let session = try! #require(engine.only())
        let policy = StalenessPolicy.standard
        #expect(policy.evaluate(session, now: f.start.addingTimeInterval(8 * 3600), processAlive: true).state == .waitingUser)
        #expect(policy.evaluate(session, now: f.start.addingTimeInterval(8 * 3600), processAlive: nil).state == .stale)
    }

    @Test("Process exit without SessionEnd ends the session; an open turn becomes interrupted")
    func reconciliation() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        let synthesized = engine.reconcileProcessLiveness(now: f.start.addingTimeInterval(60)) { _ in false }
        #expect(synthesized.count == 1)
        let session = try! #require(engine.only())
        #expect(session.lifecycle == .ended)
        #expect(session.state == .interrupted)
        #expect(session.endReason == "process_exited")
        // Already ended: nothing more is synthesised.
        #expect(engine.reconcileProcessLiveness(now: f.start.addingTimeInterval(120)) { _ in false }.isEmpty)
    }

    @Test("Bounded buffers keep the session correct beyond the buffer size")
    func boundedBuffer() {
        var f = EventFactory()
        let engine = AgentSessionEngine(configuration: .init(maxBufferedEventsPerSession: 8))
        engine.ingest(f.make(.promptSubmitted, at: 0))
        for index in 0..<50 {
            let tool = EventFactory.read("f\(index)", id: "r\(index)")
            engine.ingest(f.make(.toolStarted, at: Double(index) + 1, tool: tool))
            engine.ingest(f.make(.toolCompleted, at: Double(index) + 1.5, tool: tool))
        }
        engine.ingest(f.make(.turnCompleted, at: 100))
        #expect(engine.bufferedEvents(for: SessionKey(provider: .claudeCode, sessionID: "s1")).count == 8)
        #expect(engine.only()?.lastTurn?.toolCount == 50)
        #expect(engine.only()?.state == .completed)
    }
}

/// Deterministic RNG so shuffles are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
