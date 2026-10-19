import Foundation

/// One row of a session timeline. Rows carry data, not text: the UI localises them.
public struct TimelineEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case sessionStarted
        case prompt
        case tool
        case fileChanges
        case tests
        case subagentStarted
        case subagentStopped
        case approvalRequested
        case approvalResolved
        case error
        case turnCompleted
        case turnFailed
        case turnInterrupted
        case sessionEnded
        case processExited
        case notification
        case compaction
        case plan
        case task
    }

    public enum Outcome: String, Sendable, Hashable {
        case running
        case succeeded
        case failed
        case unknown
    }

    public var id: String
    public var kind: Kind
    public var at: Date
    public var endedAt: Date?
    public var outcome: Outcome
    public var activity: ActivityKind?
    public var tool: ToolInfo?
    public var failure: FailureInfo?
    public var attention: AttentionInfo?
    public var task: TaskInfo?
    public var subagentID: String?
    public var subagentType: String?
    /// Number of collapsed events of the same kind (1 for single events).
    public var count: Int
    /// Sanitized details of grouped items (file names, commands).
    public var items: [String]
    public var collection: CollectionMethod
    public var confidence: Confidence
    public var sourceEvent: String?
    public var metadata: [String: String]

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(at) } }
}

/// Turns raw events into a readable timeline: tool start/finish pairs become one row, and
/// runs of similar quiet operations (reading or searching files) collapse into a group.
public enum TimelineBuilder {
    public static func build(_ events: [AgentEvent]) -> [TimelineEntry] {
        let ordered = events.sorted { $0.order < $1.order }
        var entries: [TimelineEntry] = []
        var openTools: [String: Int] = [:]

        for event in ordered {
            switch event.kind {
            case .toolStarted:
                guard let tool = event.tool else { continue }
                let entry = TimelineEntry(
                    id: event.id,
                    kind: tool.activity == .runningTests ? .tests : .tool,
                    at: event.occurredAt,
                    endedAt: nil,
                    outcome: .running,
                    activity: tool.activity,
                    tool: tool,
                    count: 1,
                    items: tool.summary.map { [$0] } ?? [],
                    event: event
                )
                entries.append(entry)
                if let useID = tool.useID { openTools[useID] = entries.count - 1 }

            case .toolCompleted, .toolFailed:
                guard let tool = event.tool else { continue }
                let failed = event.kind == .toolFailed
                if let useID = tool.useID, let index = openTools.removeValue(forKey: useID) {
                    entries[index].endedAt = event.occurredAt
                    entries[index].outcome = failed ? .failed : .succeeded
                    entries[index].failure = event.failure
                    entries[index].tool?.durationMillis = tool.durationMillis
                    entries[index].tool?.exitCode = tool.exitCode
                    if !tool.filePaths.isEmpty { entries[index].tool?.filePaths = tool.filePaths }
                } else {
                    entries.append(TimelineEntry(
                        id: event.id,
                        kind: tool.activity == .runningTests ? .tests : .tool,
                        at: event.occurredAt,
                        endedAt: event.occurredAt,
                        outcome: failed ? .failed : .succeeded,
                        activity: tool.activity,
                        tool: tool,
                        failure: event.failure,
                        count: 1,
                        items: tool.summary.map { [$0] } ?? [],
                        event: event
                    ))
                }

            case .toolBatchCompleted, .heartbeat, .sessionDiscovered:
                continue

            case .permissionRequested, .attentionNeeded:
                entries.append(TimelineEntry(id: event.id, kind: .approvalRequested, at: event.occurredAt, outcome: .running,
                                             tool: event.tool, attention: event.attention, event: event))
            case .permissionDenied, .approvalResolved:
                entries.append(TimelineEntry(id: event.id, kind: .approvalResolved, at: event.occurredAt,
                                             outcome: event.kind == .permissionDenied ? .failed : .succeeded,
                                             tool: event.tool, attention: event.attention, event: event))
            case .sessionStarted:
                entries.append(TimelineEntry(id: event.id, kind: .sessionStarted, at: event.occurredAt, outcome: .succeeded, event: event))
            case .promptSubmitted, .turnStarted:
                entries.append(TimelineEntry(id: event.id, kind: .prompt, at: event.occurredAt, outcome: .succeeded, event: event))
            case .subagentStarted:
                entries.append(TimelineEntry(id: event.id, kind: .subagentStarted, at: event.occurredAt, outcome: .running, event: event))
            case .subagentStopped:
                entries.append(TimelineEntry(id: event.id, kind: .subagentStopped, at: event.occurredAt, outcome: .succeeded, event: event))
            case .turnCompleted:
                entries.append(TimelineEntry(id: event.id, kind: .turnCompleted, at: event.occurredAt, outcome: .succeeded, event: event))
            case .turnFailed:
                entries.append(TimelineEntry(id: event.id, kind: .turnFailed, at: event.occurredAt, outcome: .failed, failure: event.failure, event: event))
            case .turnInterrupted:
                entries.append(TimelineEntry(id: event.id, kind: .turnInterrupted, at: event.occurredAt, outcome: .unknown, event: event))
            case .sessionEnded:
                entries.append(TimelineEntry(id: event.id, kind: .sessionEnded, at: event.occurredAt, outcome: .succeeded, event: event))
            case .processExited:
                entries.append(TimelineEntry(id: event.id, kind: .processExited, at: event.occurredAt, outcome: .unknown, event: event))
            case .notification, .idleReminder:
                entries.append(TimelineEntry(id: event.id, kind: .notification, at: event.occurredAt, outcome: .succeeded, attention: event.attention, event: event))
            case .compactionStarted, .compactionFinished:
                entries.append(TimelineEntry(id: event.id, kind: .compaction, at: event.occurredAt,
                                             outcome: event.kind == .compactionFinished ? .succeeded : .running, event: event))
            case .planUpdated:
                entries.append(TimelineEntry(id: event.id, kind: .plan, at: event.occurredAt, outcome: .succeeded, event: event))
            case .taskCreated, .taskUpdated, .taskCompleted:
                entries.append(TimelineEntry(id: event.id, kind: .task, at: event.occurredAt,
                                             outcome: event.kind == .taskCompleted ? .succeeded : .running, task: event.task, event: event))
            case .fileChanged:
                entries.append(TimelineEntry(id: event.id, kind: .fileChanges, at: event.occurredAt, outcome: .succeeded,
                                             items: event.tool?.filePaths ?? [], event: event))
            }
        }
        // A tool still "running" after its turn ended never reported back (for example a
        // permission was denied); show its outcome as unknown instead of running forever.
        var turnClosedAt: Date?
        for index in entries.indices.reversed() {
            switch entries[index].kind {
            case .turnCompleted, .turnFailed, .turnInterrupted, .sessionEnded, .processExited:
                turnClosedAt = entries[index].at
            case .prompt:
                turnClosedAt = nil
            default:
                if entries[index].outcome == .running, turnClosedAt != nil,
                   [.tool, .tests, .approvalRequested].contains(entries[index].kind) {
                    entries[index].outcome = .unknown
                }
            }
        }
        return group(entries)
    }

    /// Collapses consecutive successful reads/searches (same subagent) into one row.
    static func group(_ entries: [TimelineEntry]) -> [TimelineEntry] {
        let groupable: Set<ActivityKind> = [.readingFiles, .searchingCode, .editingCode, .planning]
        var result: [TimelineEntry] = []
        for entry in entries {
            if entry.kind == .tool, let activity = entry.activity, groupable.contains(activity), entry.outcome == .succeeded,
               var last = result.last, last.kind == .tool, last.activity == activity, last.outcome == .succeeded,
               last.subagentID == entry.subagentID {
                last.count += entry.count
                last.endedAt = entry.endedAt ?? entry.at
                for item in entry.items where !last.items.contains(item) && last.items.count < 12 {
                    last.items.append(item)
                }
                result[result.count - 1] = last
            } else {
                result.append(entry)
            }
        }
        return result
    }
}

extension TimelineEntry {
    init(
        id: String,
        kind: Kind,
        at: Date,
        endedAt: Date? = nil,
        outcome: Outcome,
        activity: ActivityKind? = nil,
        tool: ToolInfo? = nil,
        failure: FailureInfo? = nil,
        attention: AttentionInfo? = nil,
        task: TaskInfo? = nil,
        count: Int = 1,
        items: [String] = [],
        event: AgentEvent
    ) {
        self.init(
            id: id,
            kind: kind,
            at: at,
            endedAt: endedAt,
            outcome: outcome,
            activity: activity,
            tool: tool,
            failure: failure,
            attention: attention,
            task: task,
            subagentID: event.subagentID,
            subagentType: event.subagentType,
            count: count,
            items: items,
            collection: event.collection,
            confidence: event.confidence,
            sourceEvent: event.sourceEvent,
            metadata: event.metadata
        )
    }
}
