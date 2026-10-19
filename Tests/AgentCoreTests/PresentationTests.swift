@testable import AgentCore
import Foundation
import Testing

@Suite("Presentation: priority, island modes, classifiers, timeline")
struct PresentationTests {
    @Test("A session waiting for the user is never hidden behind working sessions")
    func attentionHasPriority() {
        var sessions: [AgentSession] = []
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<10 {
            var f = EventFactory(sessionID: "w\(index)", start: start)
            let engine = AgentSessionEngine()
            engine.ingest(f.make(.promptSubmitted, at: Double(index)))
            sessions.append(engine.only()!)
        }
        var f = EventFactory(provider: .codex, sessionID: "needs-you", start: start)
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.permissionRequested, at: 1, tool: EventFactory.bash("rm -rf x", id: "b"), attention: AttentionInfo(kind: .permission)))
        sessions.append(engine.only()!)

        let summary = AgentPresenter.summarize(sessions, now: start.addingTimeInterval(20))
        #expect(summary.primary?.session.sessionID == "needs-you")
        #expect(summary.mode == .attention(SessionKey(provider: .codex, sessionID: "needs-you")))
        #expect(summary.attentionCount == 1)
        #expect(summary.workingCount == 10)
        #expect(summary.providers.first == .codex)
    }

    @Test("Muted sessions do not take over the island")
    func mutedAttention() {
        var f = EventFactory(sessionID: "muted")
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.permissionRequested, at: 1, attention: AttentionInfo(kind: .permission)))
        let key = SessionKey(provider: .claudeCode, sessionID: "muted")
        let summary = AgentPresenter.summarize([engine.only()!], now: f.start.addingTimeInterval(5), muted: [key])
        #expect(summary.mode != .attention(key))
        #expect(summary.sessions.first?.isMuted == true)
    }

    @Test("Completion flashes briefly, then the island returns to its aggregate state")
    func completionFlash() {
        var f = EventFactory()
        let engine = AgentSessionEngine()
        engine.ingest(f.make(.promptSubmitted, at: 0))
        engine.ingest(f.make(.turnCompleted, at: 10))
        let session = engine.only()!
        let key = session.key
        #expect(AgentPresenter.summarize([session], now: f.start.addingTimeInterval(11)).mode == .completionFlash(key))
        let later = AgentPresenter.summarize([session], now: f.start.addingTimeInterval(20))
        #expect(later.mode == .compact)
        #expect(later.sessions.first?.category == .recentCompletion)
        #expect(later.nextChangeAt != nil)
    }

    @Test("Command classification uses the literal programs")
    func commandClassifier() {
        #expect(CommandClassifier.activity(for: "swift test --parallel") == .runningTests)
        #expect(CommandClassifier.activity(for: "cd app && npm run test:unit") == .runningTests)
        #expect(CommandClassifier.activity(for: "FOO=1 python3 -m pytest -q") == .runningTests)
        #expect(CommandClassifier.activity(for: "xcodebuild -scheme App test") == .runningTests)
        #expect(CommandClassifier.activity(for: "xcodebuild -scheme App build") == .building)
        #expect(CommandClassifier.activity(for: "npm install && npm run build") == .building)
        #expect(CommandClassifier.activity(for: "git status") == .usingGit)
        #expect(CommandClassifier.activity(for: "ls -la") == .runningCommand)
        #expect(CommandClassifier.activity(for: "echo 'npm test'") == .runningCommand)
        #expect(CommandClassifier.summary(for: "API=1 swift test --filter Foo") == "swift test")
        #expect(ToolClassifier.activity(toolName: "Edit") == .editingCode)
        #expect(ToolClassifier.activity(toolName: "mcp__github__search") == .usingTool)
        #expect(ToolClassifier.displayName(toolName: "mcp__github__search_repositories") == "github · search_repositories")
    }

    @Test("Timeline pairs tool start/finish and groups consecutive reads")
    func timeline() {
        var f = EventFactory()
        var events = [f.make(.promptSubmitted, at: 0)]
        for index in 0..<5 {
            let tool = EventFactory.read("f\(index).swift", id: "r\(index)")
            events.append(f.make(.toolStarted, at: Double(index) + 1, tool: tool))
            events.append(f.make(.toolCompleted, at: Double(index) + 1.2, tool: tool))
        }
        let test = EventFactory.bash("swift test", id: "t")
        events.append(f.make(.toolStarted, at: 7, tool: test))
        events.append(f.make(.toolFailed, at: 12, tool: test, failure: FailureInfo(category: .tests, code: "1")))
        events.append(f.make(.turnCompleted, at: 13))

        let entries = TimelineBuilder.build(events)
        #expect(entries.map(\.kind) == [.prompt, .tool, .tests, .turnCompleted])
        #expect(entries[1].count == 5)
        #expect(entries[1].items.count == 5)
        #expect(entries[2].outcome == .failed)
        #expect(entries[2].duration == 5)
    }

    @Test("The demo scenario exercises every category, flagged as demo")
    func demoScenario() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let at20 = DemoScenario.sessions(at: 20, start: start)
        let summary = AgentPresenter.summarize(at20, now: start.addingTimeInterval(20))
        #expect(summary.attentionCount == 1)
        #expect(summary.workingCount >= 2)
        let allDemo = at20.allSatisfy(\.isDemo)
        #expect(allDemo)
        let at32 = DemoScenario.sessions(at: 32, start: start)
        let hasFailure = at32.contains { $0.state == .failed }
        #expect(hasFailure)
        let at45 = DemoScenario.sessions(at: 45, start: start)
        let alocativaDone = at45.contains { $0.sessionID == "demo-alocativa" && $0.state == .completed }
        #expect(alocativaDone)
    }

    @Test("Projects are derived from the repository root")
    func projectResolver() {
        let resolver = ProjectResolver(homeDirectory: "/Users/me") { path in path == "/Users/me/code/Alocativa/.git" }
        let info = resolver.resolve("/Users/me/code/Alocativa/Sources/App")
        #expect(info?.name == "Alocativa")
        #expect(info?.rootPath == "/Users/me/code/Alocativa")
        #expect(info?.monogram == "A")
        #expect(resolver.resolve("/tmp/scratch")?.name == "scratch")
    }
}
