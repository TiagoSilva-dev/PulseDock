import AgentCore
@testable import Persistence
import Foundation
import Testing

@Suite("Persistence: SQLite history, settings, privacy")
struct PersistenceTests {
    func makeController() throws -> PersistenceController {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-db-\(UUID().uuidString)/pulsedock.sqlite")
        return try PersistenceController(url: url)
    }

    func sampleEvents(provider: AgentProvider = .claudeCode, collection: CollectionMethod = .claudeHook) -> [AgentEvent] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let kinds: [AgentEventKind] = [.promptSubmitted, .toolStarted, .turnCompleted]
        var events: [AgentEvent] = []
        for (index, kind) in kinds.enumerated() {
            let date = start.addingTimeInterval(Double(index))
            var tool: ToolInfo?
            if kind == .toolStarted {
                tool = ToolInfo(name: "Read", useID: "r", activity: .readingFiles, summary: "a.swift",
                                filePaths: ["/Users/dev/secret-client/app/a.swift"])
            }
            let event = AgentEvent(
                id: "\(provider.rawValue)-\(index)",
                provider: provider,
                sessionID: "s1",
                kind: kind,
                receivedAt: date,
                order: EventOrder(date: date),
                collection: collection,
                projectPath: "/Users/dev/secret-client/app",
                tool: tool
            )
            events.append(event)
        }
        return events
    }

    @Test("Schema is migrated and settings round-trip")
    func settings() throws {
        let controller = try makeController()
        #expect(controller.schemaVersion == Migrations.latestVersion)
        controller.saveSetting(["a": 1, "b": 2], key: "test")
        controller.flush()
        #expect(controller.loadSetting([String: Int].self, key: "test") == ["a": 1, "b": 2])
    }

    @Test("Events and sessions persist and come back in order")
    func roundTrip() async throws {
        let controller = try makeController()
        let events = sampleEvents()
        let engine = AgentSessionEngine()
        engine.ingest(events)
        controller.record(events: events, sessions: Array(engine.sessions.values), policy: PersistencePolicy())
        controller.flush()
        let key = SessionKey(provider: .claudeCode, sessionID: "s1")
        let loaded = await controller.events(for: key)
        #expect(loaded.map(\.id) == events.map(\.id))
        let sessions = await controller.sessions(since: Date(timeIntervalSince1970: 0))
        #expect(sessions.first?.state == .completed)
        let stats = await controller.statistics()
        #expect(stats.events == 3)
        #expect(stats.sessions == 1)
    }

    @Test("Demo fixtures are never written")
    func demoNotPersisted() async throws {
        let controller = try makeController()
        let events = sampleEvents(collection: .fixture)
        let engine = AgentSessionEngine()
        engine.ingest(events)
        controller.record(events: events, sessions: Array(engine.sessions.values), policy: PersistencePolicy())
        controller.flush()
        #expect(await controller.statistics().events == 0)
    }

    @Test("History can be disabled, paths stripped, and deleted")
    func privacy() async throws {
        let controller = try makeController()
        let engine = AgentSessionEngine()
        let events = sampleEvents()
        engine.ingest(events)
        controller.record(events: events, sessions: Array(engine.sessions.values), policy: PersistencePolicy(storeHistory: false))
        controller.flush()
        #expect(await controller.statistics().events == 0)

        controller.record(events: events, sessions: Array(engine.sessions.values), policy: PersistencePolicy(storePaths: false))
        controller.flush()
        let stored = await controller.events(for: SessionKey(provider: .claudeCode, sessionID: "s1"))
        #expect(stored.allSatisfy { !($0.projectPath ?? "").contains("/") })
        #expect(stored.compactMap(\.tool).allSatisfy { $0.filePaths.allSatisfy { !$0.contains("/") } })

        // Only the last path component is kept, so the parent folder name is not searchable.
        let hidden = await controller.history(HistoryQuery(text: "secret-client"))
        #expect(hidden.isEmpty)
        let found = await controller.history(HistoryQuery(text: "app"))
        #expect(found.count == 1)
        let none = await controller.history(HistoryQuery(providers: [.codex]))
        #expect(none.isEmpty)

        await withCheckedContinuation { continuation in controller.deleteHistory { continuation.resume() } }
        #expect(await controller.statistics().sessions == 0)
    }

    @Test("Retention removes old history")
    func retention() async throws {
        let controller = try makeController()
        let events = sampleEvents()
        let engine = AgentSessionEngine()
        engine.ingest(events)
        controller.record(events: events, sessions: Array(engine.sessions.values), policy: PersistencePolicy())
        controller.applyRetention(PersistencePolicy(retentionDays: 1), now: Date(timeIntervalSince1970: 1_800_000_000 + 3 * 86_400))
        controller.flush()
        #expect(await controller.statistics().events == 0)
    }
}
