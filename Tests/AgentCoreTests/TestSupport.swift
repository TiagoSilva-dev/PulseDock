@testable import AgentCore
import Foundation

/// Builds events with deterministic ids and times for reducer tests.
struct EventFactory {
    var provider: AgentProvider = .claudeCode
    var sessionID = "s1"
    var start = Date(timeIntervalSince1970: 1_800_000_000)
    /// Prefix for generated ids when several factories feed one engine (ids are global there).
    var idPrefix = ""
    private(set) var counter = 0

    mutating func make(
        _ kind: AgentEventKind,
        at offset: TimeInterval,
        turn: String? = "p1",
        tool: ToolInfo? = nil,
        attention: AttentionInfo? = nil,
        failure: FailureInfo? = nil,
        task: TaskInfo? = nil,
        subagent: String? = nil,
        subagentType: String? = nil,
        collection: CollectionMethod = .claudeHook,
        metadata: [String: String] = [:]
    ) -> AgentEvent {
        counter += 1
        let date = start.addingTimeInterval(offset)
        return AgentEvent(
            id: "\(idPrefix)e\(counter)",
            provider: provider,
            sessionID: sessionID,
            kind: kind,
            receivedAt: date,
            order: EventOrder(wallMillis: Int64(date.timeIntervalSince1970 * 1000), bootID: "boot", monotonicNanos: UInt64(offset * 1_000_000_000) + 1),
            collection: collection,
            turnID: turn,
            subagentID: subagent,
            subagentType: subagentType,
            projectPath: "/tmp/project",
            tool: tool,
            attention: attention,
            failure: failure,
            task: task,
            metadata: metadata
        )
    }

    static func bash(_ command: String, id: String, fingerprint: String? = nil) -> ToolInfo {
        ToolInfo(
            name: "Bash",
            useID: id,
            activity: CommandClassifier.activity(for: command),
            summary: CommandClassifier.summary(for: command),
            inputFingerprint: fingerprint ?? "fp-\(command)"
        )
    }

    static func read(_ file: String, id: String) -> ToolInfo {
        ToolInfo(name: "Read", useID: id, activity: .readingFiles, summary: file, inputFingerprint: "fp-read-\(file)")
    }
}

extension AgentSessionEngine {
    func only() -> AgentSession? { sessions.values.first }
}
