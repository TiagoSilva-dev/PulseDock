import Foundation

/// The session state machine: a pure function `(session, event) -> session`.
///
/// Rules that matter for reliability:
/// - A turn ending is not a task ending: `turnCompleted` sets `completed` for the turn only.
/// - Success is never inferred from silence or from a process stopping.
/// - Attention is cleared only by evidence that the request was resolved.
/// - Inferences (for example "a new prompt arrived while the previous turn never reported
///   completion, so that turn was interrupted") are deterministic and marked `.inferred`.
public enum SessionReducer {
    public static func apply(_ event: AgentEvent, to session: AgentSession) -> AgentSession {
        var s = session
        let at = event.occurredAt
        let wasNew = session.eventCount == 0

        s.eventCount += 1
        s.collectionMethods.insert(event.collection)
        s.capabilities = s.capabilities.union(.for(event.collection))
        if wasNew { s.firstSeenAt = min(s.firstSeenAt, at) }
        if event.kind != .heartbeat && event.kind != .sessionDiscovered {
            s.lastEventAt = max(s.lastEventAt, at)
        }
        s.lastEvidenceAt = max(s.lastEvidenceAt, at)
        absorbContext(of: event, into: &s)

        if s.lifecycle == .ended, reactivates(event.kind) {
            s.lifecycle = .active
            s.endedAt = nil
            s.endReason = nil
        }

        switch event.kind {
        case .sessionStarted:
            s.lifecycle = .active
            if s.startedAt == nil { s.startedAt = at }
            // Compaction re-fires SessionStart mid-turn; it must not reset work in progress.
            if event.metadata["source"] != "compact", s.currentTurn == nil, s.pendingAttentions.isEmpty {
                setState(&s, .idle, .confirmed, "session_started", at)
            }

        case .sessionDiscovered:
            if wasNew { setState(&s, .unknown, .inferred, "discovered_without_events", at) }

        case .promptSubmitted, .turnStarted:
            if let current = s.currentTurn {
                if let turnID = event.turnID, current.id == turnID {
                    setState(&s, s.pendingAttentions.isEmpty ? .working : .waitingUser, .confirmed, "turn_continued", at)
                    break
                }
                finishTurn(&s, .interrupted, .inferred, "superseded_by_new_prompt", at)
            }
            startTurn(&s, id: event.turnID ?? event.id, confidence: .confirmed, command: event.metadata["command"], at: at)
            s.pendingAttentions.removeAll()
            s.toolsInFlight.removeAll()
            s.recentFailure = nil
            s.awaitingInputSince = nil
            s.activity = ActivityDescriptor(kind: .thinking, since: at)
            setState(&s, .working, .confirmed, "turn_started", at)

        case .toolStarted:
            guard let tool = event.tool else { break }
            ensureTurn(&s, for: event, at: at)
            s.currentTurn?.toolCount += 1
            s.toolsInFlight[toolKey(tool, event: event)] = ToolInFlight(tool: tool, startedAt: at, subagentID: event.subagentID)
            if let subagentID = event.subagentID { s.subagents[subagentID]?.toolCount += 1 }
            switch tool.activity {
            case .askingUser:
                addAttention(&s, AttentionInfo(kind: .question, toolName: tool.name, summary: tool.summary), event: event, at: at)
            case .awaitingPlanApproval:
                addAttention(&s, AttentionInfo(kind: .planApproval, toolName: tool.name, summary: tool.summary), event: event, at: at)
            default:
                break
            }
            clearNotificationAttentions(&s)
            s.activity = ActivityDescriptor(kind: tool.activity, detail: tool.summary, toolUseID: tool.useID, subagentID: event.subagentID, since: at)
            setState(&s, s.pendingAttentions.isEmpty ? .working : .waitingUser, .confirmed, "tool_started", at)

        case .toolCompleted, .toolFailed:
            guard let tool = event.tool else { break }
            ensureTurn(&s, for: event, at: at)
            removeInFlight(&s, tool: tool, event: event)
            s.pendingAttentions.removeAll { request in
                if let useID = request.toolUseID, useID == tool.useID { return true }
                if request.info.kind == .permission, request.info.toolName == tool.name, request.subagentID == event.subagentID {
                    return request.inputFingerprint == nil || tool.inputFingerprint == nil || request.inputFingerprint == tool.inputFingerprint
                }
                return false
            }
            clearNotificationAttentions(&s)
            if event.kind == .toolFailed {
                s.currentTurn?.failedToolCount += 1
                s.recentFailure = FailureRecord(info: event.failure ?? FailureInfo(category: .tool), at: at, toolName: tool.name)
            }
            refreshActivity(&s, at: at)
            setState(&s, s.pendingAttentions.isEmpty ? .working : .waitingUser, .confirmed,
                     event.kind == .toolFailed ? "tool_failed" : "tool_completed", at)

        case .toolBatchCompleted:
            let scope = event.subagentID
            s.toolsInFlight = s.toolsInFlight.filter { $0.value.subagentID != scope }
            s.pendingAttentions.removeAll { $0.subagentID == scope && $0.info.kind != .input && $0.info.kind != .elicitation }
            clearNotificationAttentions(&s)
            if s.currentTurn != nil {
                refreshActivity(&s, at: at)
                setState(&s, s.pendingAttentions.isEmpty ? .working : .waitingUser, .confirmed, "tool_batch_completed", at)
            }

        case .permissionRequested:
            ensureTurn(&s, for: event, at: at)
            let info = event.attention ?? AttentionInfo(kind: .permission, toolName: event.tool?.name, summary: event.tool?.summary)
            addAttention(&s, info, event: event, at: at)
            setState(&s, .waitingUser, .confirmed, "permission_requested", at)

        case .permissionDenied:
            s.pendingAttentions.removeAll { request in
                (request.toolUseID != nil && request.toolUseID == event.tool?.useID)
                    || (request.info.kind == .permission && request.info.toolName == event.tool?.name)
            }
            if s.currentTurn != nil {
                setState(&s, s.pendingAttentions.isEmpty ? .working : .waitingUser, .confirmed, "permission_denied", at)
            }

        case .approvalResolved:
            if let requestID = event.attention?.requestID {
                s.pendingAttentions.removeAll { $0.info.requestID == requestID }
            } else {
                s.pendingAttentions.removeAll { $0.info.kind == .permission }
            }
            if s.currentTurn != nil {
                setState(&s, s.pendingAttentions.isEmpty ? .working : .waitingUser, .confirmed, "approval_resolved", at)
            }

        case .attentionNeeded:
            let info = event.attention ?? AttentionInfo(kind: .other)
            let alreadyTracked = s.pendingAttentions.contains { $0.info.kind == info.kind && $0.subagentID == event.subagentID }
            if !alreadyTracked {
                s.pendingAttentions.append(AttentionRequest(info: info, requestedAt: at, toolUseID: nil, inputFingerprint: nil, subagentID: event.subagentID))
            }
            setState(&s, .waitingUser, .confirmed, "attention_needed", at)

        case .idleReminder:
            // The agent says it finished a while ago. If we still think a turn is running,
            // its Stop never arrived: Claude Code does not send Stop on user interrupts.
            if s.currentTurn != nil {
                finishTurn(&s, .interrupted, .inferred, "idle_after_unfinished_turn", at)
                s.toolsInFlight.removeAll()
                s.pendingAttentions.removeAll()
                s.activity = nil
                setState(&s, .interrupted, .inferred, "idle_after_unfinished_turn", at)
            }
            s.awaitingInputSince = s.awaitingInputSince ?? at

        case .notification, .fileChanged, .heartbeat:
            break

        case .subagentStarted:
            guard let subagentID = event.subagentID else { break }
            var record = s.subagents[subagentID] ?? SubagentRecord(
                id: subagentID, type: nil, description: nil, startedAt: at, endedAt: nil, status: .running, toolCount: 0
            )
            record.type = event.subagentType ?? record.type
            record.description = event.metadata["description"] ?? record.description
            record.status = .running
            record.endedAt = nil
            record.startedAt = record.startedAt ?? at
            s.subagents[subagentID] = record
            if s.currentTurn != nil {
                if s.toolsInFlight.isEmpty {
                    s.activity = ActivityDescriptor(kind: .delegating, detail: record.type, subagentID: subagentID, since: at)
                }
                setState(&s, s.pendingAttentions.isEmpty ? .working : .waitingUser, .confirmed, "subagent_started", at)
            }

        case .subagentStopped:
            guard let subagentID = event.subagentID else { break }
            if var record = s.subagents[subagentID] {
                record.status = .completed
                record.endedAt = at
                s.subagents[subagentID] = record
            } else if let type = event.subagentType, !type.isEmpty {
                // Internal agents (prompt suggestions, side questions) stop with an empty type
                // and were never started; only real subagents get a record.
                s.subagents[subagentID] = SubagentRecord(
                    id: subagentID, type: type, description: nil, startedAt: nil, endedAt: at, status: .completed, toolCount: 0
                )
            }
            s.toolsInFlight = s.toolsInFlight.filter { $0.value.subagentID != subagentID }
            s.pendingAttentions.removeAll { $0.subagentID == subagentID }
            if s.activity?.subagentID == subagentID { refreshActivity(&s, at: at) }
            if s.currentTurn != nil {
                setState(&s, s.pendingAttentions.isEmpty ? .working : .waitingUser, .confirmed, "subagent_stopped", at)
            }

        case .taskCreated, .taskUpdated, .taskCompleted:
            guard let task = event.task else { break }
            let status: TaskStatus = event.kind == .taskCompleted ? .completed : task.status
            if let index = s.tasks.firstIndex(where: { $0.id == task.id }) {
                s.tasks[index].status = status
                s.tasks[index].subject = task.subject ?? s.tasks[index].subject
                if status == .completed { s.tasks[index].completedAt = at }
            } else {
                s.tasks.append(TaskRecord(id: task.id, subject: task.subject, status: status, createdAt: at, completedAt: status == .completed ? at : nil))
            }

        case .planUpdated:
            s.plan = event.plan

        case .compactionStarted:
            s.activity = ActivityDescriptor(kind: .compacting, since: at)
            setState(&s, .working, .confirmed, "compacting", at)

        case .compactionFinished:
            if s.currentTurn != nil {
                refreshActivity(&s, at: at)
                setState(&s, s.pendingAttentions.isEmpty ? .working : .waitingUser, .confirmed, "compaction_finished", at)
            } else {
                s.activity = nil
                setState(&s, .idle, .confirmed, "compaction_finished", at)
            }

        case .turnCompleted:
            closeTurn(&s, as: .completed, event: event, reason: "turn_completed", at: at)
            s.backgroundTaskCount = Int(event.metadata["background_tasks"] ?? "") ?? 0
            s.awaitingInputSince = at
            setState(&s, .completed, .confirmed, "turn_completed", at)

        case .turnFailed:
            closeTurn(&s, as: .failed, event: event, reason: event.failure?.code ?? "turn_failed", at: at)
            s.recentFailure = FailureRecord(info: event.failure ?? FailureInfo(category: .agent), at: at, toolName: nil)
            setState(&s, .failed, .confirmed, "turn_failed", at)

        case .turnInterrupted:
            closeTurn(&s, as: .interrupted, event: event, reason: "interrupted", at: at)
            setState(&s, .interrupted, .confirmed, "turn_interrupted", at)

        case .sessionEnded, .processExited:
            let reason = event.kind == .processExited ? "process_exited" : (event.metadata["reason"] ?? "ended")
            if s.currentTurn != nil {
                finishTurn(&s, .interrupted, .inferred, "\(reason)_during_turn", at)
                setState(&s, .interrupted, .inferred, "\(reason)_during_turn", at)
            } else if !s.state.isQuiescent {
                setState(&s, .idle, event.kind == .processExited ? .inferred : .confirmed, reason, at)
            }
            s.toolsInFlight.removeAll()
            s.pendingAttentions.removeAll()
            s.activity = nil
            for (id, record) in s.subagents where record.status == .running {
                var updated = record
                updated.status = .unknown
                updated.endedAt = at
                s.subagents[id] = updated
            }
            s.lifecycle = .ended
            s.endedAt = at
            s.endReason = reason
        }
        return s
    }

    // MARK: - Helpers

    private static func reactivates(_ kind: AgentEventKind) -> Bool {
        switch kind {
        case .sessionEnded, .processExited, .heartbeat, .sessionDiscovered, .notification, .idleReminder, .subagentStopped:
            false
        default:
            true
        }
    }

    private static func absorbContext(of event: AgentEvent, into s: inout AgentSession) {
        if let origin = event.origin {
            s.origin = s.origin?.merged(with: origin) ?? origin
        }
        if let root = event.origin?.projectRoot, !root.isEmpty {
            s.projectPath = root
        } else if s.projectPath == nil, let path = event.projectPath, !path.isEmpty {
            s.projectPath = path
        }
        if let cwd = event.projectPath, !cwd.isEmpty { s.currentDirectory = cwd }
        if let model = event.metadata["model"], !model.isEmpty { s.model = model }
        if let mode = event.metadata["permission_mode"], !mode.isEmpty { s.permissionMode = mode }
        if let title = event.metadata["session_title"], !title.isEmpty { s.title = title }
    }

    private static func setState(_ s: inout AgentSession, _ state: SessionState, _ confidence: Confidence, _ reason: String, _ at: Date) {
        if s.state != state || s.stateReason != reason || s.stateConfidence != confidence {
            if s.state != state { s.lastStateChangeAt = at }
            s.state = state
            s.stateConfidence = confidence
            s.stateReason = reason
        }
    }

    private static func startTurn(_ s: inout AgentSession, id: String, confidence: Confidence, command: String?, at: Date) {
        s.currentTurn = TurnRecord(id: id, startedAt: at, state: .running, confidence: confidence, command: command)
        s.turnCount += 1
    }

    /// Ensures a running turn exists for activity events. If PulseDock started mid-turn or
    /// missed the prompt, the turn is created as inferred.
    private static func ensureTurn(_ s: inout AgentSession, for event: AgentEvent, at: Date) {
        if let current = s.currentTurn {
            guard let turnID = event.turnID, current.id != turnID else { return }
            if current.id.hasPrefix("inferred-") {
                s.currentTurn?.id = turnID
                return
            }
            finishTurn(&s, .interrupted, .inferred, "superseded_by_new_turn", at)
        }
        startTurn(&s, id: event.turnID ?? "inferred-\(event.id)", confidence: .inferred, command: nil, at: at)
        s.awaitingInputSince = nil
    }

    private static func finishTurn(_ s: inout AgentSession, _ state: TurnState, _ confidence: Confidence, _ reason: String, _ at: Date) {
        guard var turn = s.currentTurn else { return }
        turn.state = state
        turn.endedAt = at
        turn.endReason = reason
        turn.confidence = min(turn.confidence, confidence)
        s.lastTurn = turn
        s.currentTurn = nil
    }

    private static func closeTurn(_ s: inout AgentSession, as state: TurnState, event: AgentEvent, reason: String, at: Date) {
        if s.currentTurn != nil {
            finishTurn(&s, state, .confirmed, reason, at)
        } else if let turnID = event.turnID, s.lastTurn?.id == turnID {
            // The same turn reported twice by two mechanisms (for example Codex hooks and
            // `notify`): keep the first record.
        } else {
            // End of a turn whose start PulseDock did not see.
            var turn = TurnRecord(id: event.turnID ?? "inferred-\(event.id)", startedAt: at, state: state, confidence: .inferred)
            turn.endedAt = at
            turn.endReason = reason
            s.lastTurn = turn
            s.turnCount += 1
        }
        s.toolsInFlight.removeAll()
        s.pendingAttentions.removeAll()
        s.activity = nil
    }

    private static func toolKey(_ tool: ToolInfo, event: AgentEvent) -> String {
        tool.useID ?? "\(tool.name)#\(event.subagentID ?? "main")#\(event.id)"
    }

    private static func removeInFlight(_ s: inout AgentSession, tool: ToolInfo, event: AgentEvent) {
        if let useID = tool.useID, s.toolsInFlight.removeValue(forKey: useID) != nil { return }
        // Without an id (PermissionRequest-style payloads), match the oldest call of that tool.
        if let match = s.toolsInFlight
            .filter({ $0.value.tool.name == tool.name && $0.value.subagentID == event.subagentID })
            .min(by: { $0.value.startedAt < $1.value.startedAt }) {
            s.toolsInFlight.removeValue(forKey: match.key)
        }
    }

    private static func addAttention(_ s: inout AgentSession, _ info: AttentionInfo, event: AgentEvent, at: Date) {
        let request = AttentionRequest(
            info: info,
            requestedAt: at,
            toolUseID: event.tool?.useID,
            inputFingerprint: event.tool?.inputFingerprint,
            subagentID: event.subagentID
        )
        if let requestID = info.requestID, s.pendingAttentions.contains(where: { $0.info.requestID == requestID }) { return }
        if let useID = request.toolUseID, s.pendingAttentions.contains(where: { $0.toolUseID == useID && $0.info.kind == info.kind }) { return }
        s.pendingAttentions.append(request)
    }

    /// Attention raised only by a notification (no tool id, no fingerprint) is resolved by
    /// any later sign of progress in the same session.
    private static func clearNotificationAttentions(_ s: inout AgentSession) {
        s.pendingAttentions.removeAll { $0.toolUseID == nil && $0.inputFingerprint == nil && $0.info.requestID == nil }
    }

    private static func refreshActivity(_ s: inout AgentSession, at: Date) {
        if let latest = s.toolsInFlight.values.max(by: { $0.startedAt < $1.startedAt }) {
            s.activity = ActivityDescriptor(
                kind: latest.tool.activity,
                detail: latest.tool.summary,
                toolUseID: latest.tool.useID,
                subagentID: latest.subagentID,
                since: latest.startedAt
            )
        } else if s.currentTurn != nil {
            if let running = s.runningSubagents.last {
                s.activity = ActivityDescriptor(kind: .delegating, detail: running.type, subagentID: running.id, since: running.startedAt ?? at)
            } else {
                s.activity = ActivityDescriptor(kind: .thinking, since: at)
            }
        } else {
            s.activity = nil
        }
    }
}
