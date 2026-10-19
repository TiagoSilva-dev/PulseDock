@testable import AgentCore
import Foundation
import Testing

/// Reproducible load benchmark: the specification asks for acceptable behaviour with 20 or
/// more registered sessions. Timings are printed so `scripts/benchmark.sh` can record them;
/// the limits are deliberately generous (debug build, shared CI machines) and catch only
/// order-of-magnitude regressions.
@Suite("Load: many concurrent sessions")
struct LoadTests {
    static let sessionCount = 25
    static let eventsPerSession = 200

    /// Interleaved traffic from 25 sessions: prompts, tool calls, some failures, subagents,
    /// and one session that ends up waiting for an approval.
    static func traffic() -> [AgentEvent] {
        var events: [AgentEvent] = []
        for index in 0..<sessionCount {
            var f = EventFactory()
            f.sessionID = "load-\(index)"
            f.idPrefix = "load-\(index)-"
            f.provider = index % 3 == 0 ? .codex : .claudeCode
            var t = Double(index) * 0.01
            events.append(f.make(.sessionStarted, at: t, turn: nil, metadata: ["source": "startup"]))
            var turn = 0
            while events.count < (index + 1) * eventsPerSession - 4 {
                turn += 1
                t += 1
                events.append(f.make(.promptSubmitted, at: t, turn: "p\(turn)"))
                for call in 0..<6 {
                    let tool = call % 2 == 0
                        ? EventFactory.read("file\(call).swift", id: "r\(turn)-\(call)")
                        : EventFactory.bash("swift build", id: "b\(turn)-\(call)", fingerprint: "fp\(turn)-\(call)")
                    t += 0.2
                    events.append(f.make(.toolStarted, at: t, turn: "p\(turn)", tool: tool))
                    t += 0.2
                    let failed = call == 5 && turn % 4 == 0
                    events.append(f.make(failed ? .toolFailed : .toolCompleted, at: t, turn: "p\(turn)", tool: tool,
                                         failure: failed ? FailureInfo(category: .tool, summary: "Exit code 1") : nil))
                }
                if turn % 5 == 0 {
                    events.append(f.make(.subagentStarted, at: t + 0.1, turn: "p\(turn)", subagent: "sa\(turn)", subagentType: "Explore"))
                    events.append(f.make(.subagentStopped, at: t + 0.5, turn: "p\(turn)", subagent: "sa\(turn)", subagentType: "Explore"))
                }
                t += 1
                events.append(f.make(.turnCompleted, at: t, turn: "p\(turn)"))
            }
            turn += 1
            events.append(f.make(.promptSubmitted, at: t + 1, turn: "p\(turn)"))
            if index == 7 {
                let bash = EventFactory.bash("rm -rf build", id: "perm", fingerprint: "fp-perm")
                events.append(f.make(.toolStarted, at: t + 2, turn: "p\(turn)", tool: bash))
                events.append(f.make(.permissionRequested, at: t + 2.1, turn: "p\(turn)", tool: bash,
                                     attention: AttentionInfo(kind: .permission, toolName: "Bash")))
            }
        }
        // Arrival interleaved across sessions, deterministic.
        var generator = SeededGenerator(seed: 42)
        return events.shuffled(using: &generator).sorted { $0.receivedAt < $1.receivedAt }
    }

    @Test("25 sessions × 200 events: every session is tracked and the approval stays on top")
    func manySessions() {
        let events = Self.traffic()
        let engine = AgentSessionEngine()
        let clock = ContinuousClock()

        let ingestDuration = clock.measure {
            for event in events { engine.ingest(event) }
        }
        let now = events.map(\.receivedAt).max()!.addingTimeInterval(5)
        var summary: AggregateSummary?
        let summarizeDuration = clock.measure {
            for _ in 0..<10 {
                summary = AgentPresenter.summarize(Array(engine.sessions.values), now: now, processAlive: { _ in true })
            }
        }

        #expect(engine.sessions.count == Self.sessionCount)
        let waiting = summary?.sessions.first
        #expect(waiting?.session.sessionID == "load-7")
        #expect(waiting?.category == .attention)
        if case let .attention(key) = summary?.mode { #expect(key.sessionID == "load-7") } else { Issue.record("expected attention mode") }

        let perEvent = ingestDuration / events.count
        let perSummary = summarizeDuration / 10
        print("[benchmark] ingest \(events.count) events: \(ingestDuration) (\(perEvent) per event); summarize \(Self.sessionCount) sessions: \(perSummary)")
        #expect(ingestDuration < .seconds(3))
        #expect(perSummary < .milliseconds(50))
    }
}
