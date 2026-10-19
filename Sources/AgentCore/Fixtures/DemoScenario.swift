import Foundation

/// Deterministic, declared fixtures for Demo mode and UI tests. Every event is collected as
/// `.fixture`, so sessions built from them are always flagged `isDemo` and are never
/// persisted or mixed with real integrations.
public enum DemoScenario {
    public struct Step: Sendable, Hashable {
        public var offset: TimeInterval
        public var event: AgentEvent
    }

    public static let projects = (
        alocativa: "/Users/demo/Projects/Alocativa",
        gustfire: "/Users/demo/Projects/Gustfire",
        pulsedock: "/Users/demo/Projects/PulseDock",
        orbit: "/Users/demo/Projects/Orbit"
    )

    /// A 90-second loop covering every state the brief asks the UI to represent.
    public static func standard(start: Date) -> [Step] {
        var builder = Builder(start: start)

        // 1. Claude Code · Alocativa: reads, edits, runs tests, finishes the turn.
        let alocativa = builder.session(.claudeCode, "demo-alocativa", project: projects.alocativa)
        builder.add(0, alocativa, .sessionStarted, metadata: ["source": "startup"])
        builder.add(1, alocativa, .promptSubmitted)
        builder.tool(2, alocativa, "Read", .readingFiles, "Package.swift", id: "a1", duration: 1)
        builder.tool(3.5, alocativa, "Grep", .searchingCode, "AllocationEngine", id: "a2", duration: 1.5)
        builder.tool(6, alocativa, "Edit", .editingCode, "AllocationEngine.swift", id: "a3", duration: 2)
        builder.tool(10, alocativa, "Bash", .runningTests, "swift test", id: "a4", duration: 26)
        builder.add(40, alocativa, .turnCompleted, metadata: ["background_tasks": "0"])

        // 2. Codex · Gustfire: a command that needs approval.
        let gustfire = builder.session(.codex, "demo-gustfire", project: projects.gustfire)
        builder.add(2, gustfire, .sessionStarted, metadata: ["source": "startup"])
        builder.add(3, gustfire, .promptSubmitted, turnID: "turn-g1")
        builder.tool(5, gustfire, "Bash", .runningCommand, "ls -la build", id: "g1", duration: 1, turnID: "turn-g1")
        builder.toolStart(8, gustfire, "Bash", .runningCommand, "rm -rf build/cache", id: "g2", turnID: "turn-g1")
        builder.add(8.5, gustfire, .permissionRequested, turnID: "turn-g1",
                    tool: ToolInfo(name: "Bash", activity: .runningCommand, summary: "rm -rf build/cache", inputFingerprint: "fp-g2"),
                    attention: AttentionInfo(kind: .permission, toolName: "Bash", summary: "rm -rf build/cache", reason: "Command writes outside the sandbox"))
        builder.toolEnd(52, gustfire, "Bash", .runningCommand, "rm -rf build/cache", id: "g2", turnID: "turn-g1", fingerprint: "fp-g2")
        builder.add(60, gustfire, .turnCompleted, turnID: "turn-g1")

        // 3. Claude Code · PulseDock: parallel subagents, then a finished turn.
        let pulsedock = builder.session(.claudeCode, "demo-pulsedock", project: projects.pulsedock)
        builder.add(0, pulsedock, .sessionStarted, metadata: ["source": "resume"])
        builder.add(4, pulsedock, .promptSubmitted)
        builder.tool(5, pulsedock, "Agent", .delegating, "Explore the window layer", id: "p0", duration: 0.5)
        for (index, type) in ["Explore", "Plan", "general-purpose"].enumerated() {
            builder.add(6 + Double(index), pulsedock, .subagentStarted, subagentID: "sub-\(index)", subagentType: type)
            builder.tool(8 + Double(index) * 2, pulsedock, "Read", .readingFiles, "DockWindow.swift", id: "p\(index + 1)", duration: 2, subagentID: "sub-\(index)")
            builder.add(20 + Double(index) * 4, pulsedock, .subagentStopped, subagentID: "sub-\(index)", subagentType: type)
        }
        builder.add(30, pulsedock, .taskCreated, task: TaskInfo(id: "t1", subject: "Window layer", status: .pending))
        builder.add(30.2, pulsedock, .taskCreated, task: TaskInfo(id: "t2", subject: "Magnification", status: .pending))
        builder.add(30.4, pulsedock, .taskCreated, task: TaskInfo(id: "t3", subject: "Agent Pulse", status: .pending))
        builder.add(33, pulsedock, .taskCompleted, task: TaskInfo(id: "t1", subject: "Window layer", status: .completed))
        builder.add(35, pulsedock, .taskCompleted, task: TaskInfo(id: "t2", subject: "Magnification", status: .completed))
        builder.add(36, pulsedock, .turnCompleted, metadata: ["background_tasks": "0"])

        // 4. Codex · Orbit: failing tests, then an API failure ends the turn.
        let orbit = builder.session(.codex, "demo-orbit", project: projects.orbit)
        builder.add(12, orbit, .sessionStarted, metadata: ["source": "startup"])
        builder.add(13, orbit, .promptSubmitted, turnID: "turn-o1")
        builder.toolStart(15, orbit, "Bash", .runningTests, "npm test", id: "o1", turnID: "turn-o1")
        builder.add(24, orbit, .toolFailed, turnID: "turn-o1",
                    tool: ToolInfo(name: "Bash", useID: "o1", activity: .runningTests, summary: "npm test", exitCode: 1),
                    failure: FailureInfo(category: .tests, code: "1", summary: "Exit code 1"))
        builder.add(30, orbit, .turnFailed, turnID: "turn-o1",
                    failure: FailureInfo(category: .api, code: "rate_limit", summary: "Rate limit reached"))

        return builder.steps.sorted { $0.offset < $1.offset }
    }

    /// Applies every step up to `elapsed` seconds into the scenario.
    public static func sessions(at elapsed: TimeInterval, start: Date) -> [AgentSession] {
        let engine = AgentSessionEngine()
        for step in standard(start: start) where step.offset <= elapsed {
            engine.ingest(step.event)
        }
        return Array(engine.sessions.values)
    }

    struct Builder {
        let start: Date
        var steps: [Step] = []
        var counter = 0

        struct SessionRef {
            var provider: AgentProvider
            var id: String
            var project: String
        }

        func session(_ provider: AgentProvider, _ id: String, project: String) -> SessionRef {
            SessionRef(provider: provider, id: id, project: project)
        }

        mutating func add(
            _ offset: TimeInterval,
            _ session: SessionRef,
            _ kind: AgentEventKind,
            turnID: String? = nil,
            subagentID: String? = nil,
            subagentType: String? = nil,
            tool: ToolInfo? = nil,
            attention: AttentionInfo? = nil,
            failure: FailureInfo? = nil,
            task: TaskInfo? = nil,
            metadata: [String: String] = [:]
        ) {
            counter += 1
            let date = start.addingTimeInterval(offset)
            let event = AgentEvent(
                id: "demo-\(session.id)-\(counter)",
                provider: session.provider,
                sessionID: session.id,
                kind: kind,
                receivedAt: date,
                order: EventOrder(date: date, sequence: UInt64(counter)),
                collection: .fixture,
                confidence: .confirmed,
                turnID: turnID,
                subagentID: subagentID,
                subagentType: subagentType,
                projectPath: session.project,
                sourceEvent: "demo",
                tool: tool,
                attention: attention,
                failure: failure,
                task: task,
                origin: SessionOrigin(projectRoot: session.project),
                metadata: metadata
            )
            steps.append(Step(offset: offset, event: event))
        }

        mutating func toolStart(_ offset: TimeInterval, _ session: SessionRef, _ name: String, _ activity: ActivityKind, _ summary: String,
                                id: String, turnID: String? = nil, subagentID: String? = nil) {
            add(offset, session, .toolStarted, turnID: turnID, subagentID: subagentID,
                tool: ToolInfo(name: name, useID: id, activity: activity, summary: summary))
        }

        mutating func toolEnd(_ offset: TimeInterval, _ session: SessionRef, _ name: String, _ activity: ActivityKind, _ summary: String,
                              id: String, turnID: String? = nil, subagentID: String? = nil, fingerprint: String? = nil) {
            add(offset, session, .toolCompleted, turnID: turnID, subagentID: subagentID,
                tool: ToolInfo(name: name, useID: id, activity: activity, summary: summary, inputFingerprint: fingerprint))
        }

        mutating func tool(_ offset: TimeInterval, _ session: SessionRef, _ name: String, _ activity: ActivityKind, _ summary: String,
                           id: String, duration: TimeInterval, turnID: String? = nil, subagentID: String? = nil) {
            toolStart(offset, session, name, activity, summary, id: id, turnID: turnID, subagentID: subagentID)
            toolEnd(offset + duration, session, name, activity, summary, id: id, turnID: turnID, subagentID: subagentID)
        }
    }
}
