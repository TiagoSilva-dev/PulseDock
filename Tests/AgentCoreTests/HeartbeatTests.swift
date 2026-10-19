@testable import AgentCore
import Foundation
import Testing

@Suite("Agent Heartbeat: beats from real events, quiet stays flat, Test Radar outcomes")
struct HeartbeatTests {
    @Test("Only observable agent activity produces beats; discovery and heartbeats do not")
    func beatsComeFromConcreteEvents() {
        var factory = EventFactory()
        #expect(AgentHeartbeat.beat(for: factory.make(.toolStarted, at: 0, tool: EventFactory.bash("ls", id: "t1")))?.kind == .activity)
        #expect(AgentHeartbeat.beat(for: factory.make(.permissionRequested, at: 1))?.kind == .attention)
        #expect(AgentHeartbeat.beat(for: factory.make(.toolFailed, at: 2))?.kind == .failure)
        #expect(AgentHeartbeat.beat(for: factory.make(.turnCompleted, at: 3))?.kind == .completion)
        #expect(AgentHeartbeat.beat(for: factory.make(.heartbeat, at: 4)) == nil)
        #expect(AgentHeartbeat.beat(for: factory.make(.sessionDiscovered, at: 5)) == nil)
        #expect(AgentHeartbeat.beat(for: factory.make(.processExited, at: 6)) == nil)
    }

    @Test("Lanes bucket beats by time, keep the most important kind, and drop quiet sessions")
    func lanes() {
        var first = EventFactory()
        var second = EventFactory(sessionID: "s2", idPrefix: "b")
        var early = EventFactory(sessionID: "s2", start: first.start.addingTimeInterval(-900), idPrefix: "c")
        let now = first.start.addingTimeInterval(600)
        let beats = [
            first.make(.toolStarted, at: 10, tool: EventFactory.bash("ls", id: "1")),
            first.make(.permissionRequested, at: 20),
            first.make(.toolStarted, at: 590, tool: EventFactory.bash("ls", id: "2")),
            second.make(.turnCompleted, at: 300),
            // Older than the window: ignored.
            early.make(.toolStarted, at: 0, tool: EventFactory.bash("ls", id: "3")),
        ].compactMap(AgentHeartbeat.beat(for:))
        let lanes = AgentHeartbeat.lanes(beats, now: now, window: 600, bucketCount: 10)
        #expect(lanes.count == 2)
        #expect(lanes[0].session.sessionID == "s1")
        #expect(lanes[0].counts[0] == 2)
        #expect(lanes[0].kinds[0] == .attention)
        #expect(lanes[0].counts[9] == 1)
        #expect(lanes[0].counts[1...8].allSatisfy { $0 == 0 })
        #expect(lanes[1].total == 1)
        #expect(AgentHeartbeat.lanes([], now: now, window: 600, bucketCount: 10).isEmpty)
        #expect(AgentHeartbeat.beatsPerMinute(beats, now: now, window: 600) == 0)
    }

    @Test("Test Radar: exit 0 passes, other codes fail, no code is reported as such")
    func testRuns() {
        var factory = EventFactory()
        var passing = EventFactory.bash("swift test", id: "t1")
        passing.exitCode = 0
        var failing = EventFactory.bash("npm test", id: "t2")
        failing.exitCode = 1
        let unknown = EventFactory.bash("pytest", id: "t3")
        let build = EventFactory.bash("swift build", id: "t4")

        #expect(passing.activity == .runningTests)
        #expect(AgentHeartbeat.testRun(from: factory.make(.toolCompleted, at: 1, tool: passing))?.outcome == .passed)
        #expect(AgentHeartbeat.testRun(from: factory.make(.toolCompleted, at: 2, tool: failing))?.outcome == .failed(exitCode: 1))
        #expect(AgentHeartbeat.testRun(from: factory.make(.toolCompleted, at: 3, tool: unknown))?.outcome == .finishedWithoutError)
        #expect(AgentHeartbeat.testRun(from: factory.make(.toolFailed, at: 4, tool: unknown, failure: FailureInfo(category: .tests, code: "2")))?.outcome == .failed(exitCode: 2))
        // A test command that only started has no outcome; a build is not a test.
        #expect(AgentHeartbeat.testRun(from: factory.make(.toolStarted, at: 5, tool: passing)) == nil)
        #expect(AgentHeartbeat.testRun(from: factory.make(.toolCompleted, at: 6, tool: build)) == nil)
    }

    @Test("Latest run per project wins")
    func latestRuns() {
        var factory = EventFactory()
        var ok = EventFactory.bash("swift test", id: "a")
        ok.exitCode = 0
        var bad = EventFactory.bash("swift test", id: "b")
        bad.exitCode = 1
        let runs = [
            factory.make(.toolCompleted, at: 1, tool: bad),
            factory.make(.toolCompleted, at: 2, tool: ok),
        ].compactMap(AgentHeartbeat.testRun(from:))
        let latest = AgentHeartbeat.latestRuns(runs)
        #expect(latest.count == 1)
        #expect(latest[0].outcome == .passed)
    }
}

extension HeartbeatTests {
    @Test("Demo fixtures are flagged on beats, lanes and test runs")
    func demoFlag() {
        var factory = EventFactory()
        var passing = EventFactory.bash("swift test", id: "d1")
        passing.exitCode = 0
        let event = factory.make(.toolCompleted, at: 1, tool: passing, collection: .fixture)
        let beat = AgentHeartbeat.beat(for: event)
        #expect(beat?.isDemo == true)
        #expect(AgentHeartbeat.testRun(from: event)?.isDemo == true)
        let lanes = AgentHeartbeat.lanes([beat!], now: factory.start.addingTimeInterval(10), window: 60, bucketCount: 6)
        #expect(lanes.first?.isDemo == true)
        #expect(AgentHeartbeat.beat(for: factory.make(.toolStarted, at: 2, tool: passing))?.isDemo == false)
    }
}
