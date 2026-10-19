import AgentBridge
import AgentCore
@testable import ClaudeCodeAdapter
import Foundation
import Testing

@Suite("Claude usage: status line sanitization, normalization and the usage ledger")
struct ClaudeUsageTests {
    func fixture() throws -> [String: Any] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/statusline/statusline.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test("Only usage numbers, model and project folder survive the helper")
    func sanitizer() throws {
        let input = try fixture()
        let sanitized = StatusLineSanitizer.sanitize(input)
        let text = sanitized.canonicalString
        for forbidden in ["secret plan", "transcript", "pull/1234", "acme", "security-reviewer", "prompt_id", "current_usage", "/src"] {
            #expect(!text.contains(forbidden), "\(forbidden) leaked")
        }
        #expect(sanitized["project_dir"]?.stringValue == "/Users/dev/Projects/alocativa")
        #expect(sanitized["rate_limits"]?["five_hour"]?["used_percentage"]?.numberValue == 23.5)
        #expect(sanitized["cost"]?["total_cost_usd"]?.numberValue == 1.2345)
        #expect(StatusLineSanitizer.compactLine(sanitized) == "Opus · ctx 8% · 5h 24% · 7d 41%")

        // Booleans, negatives and non-numbers never pass as numbers.
        let odd = StatusLineSanitizer.sanitize(["session_id": "s", "cost": ["total_cost_usd": true, "total_lines_added": -3, "total_duration_ms": "9"]])
        #expect(odd["cost"] == nil)
    }

    @Test("Envelope → snapshot: windows, cost and context; no session id, no snapshot")
    func normalizer() throws {
        let data = try JSONSerialization.data(withJSONObject: try fixture())
        let now = Date()
        let built = try #require(HookEnvelopeBuilder.statusLineEnvelope(rawInput: data, context: nil, startWall: Int64(now.timeIntervalSince1970 * 1000),
                                                                        startMono: nil, bootID: nil, helperPID: 1))
        // Round trip through the wire format.
        let envelope = try BridgeEnvelope.decode(line: try built.envelope.encodedLine())
        let snapshot = try #require(ClaudeUsageNormalizer.snapshot(from: envelope, receivedAt: now))
        #expect(snapshot.fiveHour?.usedPercent == 23.5)
        #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_738_425_600))
        #expect(snapshot.sevenDay?.usedPercent == 41.2)
        #expect(snapshot.costUSD == 1.2345 && snapshot.linesAdded == 156)
        #expect(snapshot.contextUsedPercent == 8 && snapshot.contextSize == 200_000)
        #expect(snapshot.modelName == "Opus")
        #expect(HookEnvelopeBuilder.statusLineEnvelope(rawInput: Data("{}".utf8), context: nil, startWall: 1, startMono: nil, bootID: nil, helperPID: 1) == nil)
    }

    @Test("Ledger: daily cost from increases, restarts and new sessions; old sessions are a lower bound")
    func dailyCost() {
        var ledger = ClaudeUsageLedger()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.apply(ClaudeUsageSnapshot(sessionID: "a", observedAt: start, costUSD: 0.5, durationMS: 60_000))
        ledger.apply(ClaudeUsageSnapshot(sessionID: "a", observedAt: start.addingTimeInterval(60), costUSD: 1.25, durationMS: 120_000))
        // An older update arriving late is ignored.
        ledger.apply(ClaudeUsageSnapshot(sessionID: "a", observedAt: start.addingTimeInterval(30), costUSD: 9, durationMS: 90_000))
        // A session already running for an hour: only later increases count.
        ledger.apply(ClaudeUsageSnapshot(sessionID: "b", observedAt: start.addingTimeInterval(90), costUSD: 7, durationMS: 3_600_000))
        ledger.apply(ClaudeUsageSnapshot(sessionID: "b", observedAt: start.addingTimeInterval(120), costUSD: 7.5, durationMS: 3_630_000))
        let day = ledger.day(start)
        #expect(abs(day.costUSD - 1.75) < 0.0001)
        #expect(day.partial)
        #expect(day.sessionIDs == ["a", "b"])
        #expect(ledger.recentSessions(now: start.addingTimeInterval(200)).map(\.sessionID) == ["b", "a"])
    }

    @Test("Ledger: limits follow the newest report, reset windows disappear, thresholds alert once")
    func limitsAndAlerts() {
        var ledger = ClaudeUsageLedger()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(3 * 3600)
        func report(_ minutes: Double, _ percent: Double, session: String = "a") -> [UsageAlert] {
            ledger.apply(ClaudeUsageSnapshot(sessionID: session, observedAt: start.addingTimeInterval(minutes * 60),
                                             fiveHour: UsageWindow(usedPercent: percent, resetsAt: reset),
                                             sevenDay: UsageWindow(usedPercent: 30, resetsAt: start.addingTimeInterval(86_400 * 3))))
        }
        #expect(report(0, 40).isEmpty)
        #expect(report(10, 82).map(\.threshold) == [80])
        #expect(report(12, 85, session: "b").isEmpty)
        #expect(report(20, 97).map(\.threshold) == [95])
        #expect(report(25, 98).isEmpty)
        #expect(ledger.currentLimits(now: start.addingTimeInterval(1800))?.fiveHour?.usedPercent == 98)
        // After the reset the 5-hour window is unknown until the next report; the weekly one stays.
        let later = ledger.currentLimits(now: reset.addingTimeInterval(1))
        #expect(later?.fiveHour == nil && later?.sevenDay?.usedPercent == 30)
    }

    @Test("Projection: only with ten minutes of growth, and only when it beats the reset")
    func projection() {
        var ledger = ClaudeUsageLedger()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(4 * 3600)
        func report(_ minutes: Double, _ percent: Double) {
            ledger.apply(ClaudeUsageSnapshot(sessionID: "a", observedAt: start.addingTimeInterval(minutes * 60),
                                             fiveHour: UsageWindow(usedPercent: percent, resetsAt: reset)))
        }
        report(0, 50)
        report(5, 55)
        #expect(ledger.fiveHourExhaustion(now: start.addingTimeInterval(300)) == nil)
        report(20, 60)
        // 10 points in 20 minutes → 40 points left → 80 more minutes.
        let eta = ledger.fiveHourExhaustion(now: start.addingTimeInterval(1200))
        #expect(eta.map { abs($0.timeIntervalSince(start.addingTimeInterval(100 * 60))) < 1 } == true)

        var slow = ClaudeUsageLedger()
        slow.apply(ClaudeUsageSnapshot(sessionID: "a", observedAt: start, fiveHour: UsageWindow(usedPercent: 10, resetsAt: start.addingTimeInterval(3600))))
        slow.apply(ClaudeUsageSnapshot(sessionID: "a", observedAt: start.addingTimeInterval(1200), fiveHour: UsageWindow(usedPercent: 12, resetsAt: start.addingTimeInterval(3600))))
        #expect(slow.fiveHourExhaustion(now: start.addingTimeInterval(1200)) == nil)
    }
}
