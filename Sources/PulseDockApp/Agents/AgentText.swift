import AgentCore
import DockRendering
import Foundation

/// Human-facing descriptions of agent data. Every label maps to a concrete event field;
/// Privacy Mode is applied here, in one place, for every surface.
struct AgentText {
    var privacyMode: Bool

    // MARK: States

    func state(_ state: SessionState) -> String {
        switch state {
        case .disconnected: tr("agent.state.disconnected", "Not connected")
        case .idle: tr("agent.state.idle", "Idle")
        case .working: tr("agent.state.working", "Working")
        case .waitingUser: tr("agent.state.waitingUser", "Needs you")
        case .waitingExternal: tr("agent.state.waitingExternal", "Waiting")
        case .completed: tr("agent.state.completed", "Turn finished")
        case .failed: tr("agent.state.failed", "Failed")
        case .interrupted: tr("agent.state.interrupted", "Interrupted")
        case .stale: tr("agent.state.stale", "No recent updates")
        case .unknown: tr("agent.state.unknown", "State unknown")
        }
    }

    static func tone(_ state: SessionState) -> StatusTone {
        switch state {
        case .working: .working
        case .waitingUser, .waitingExternal: .attention
        case .completed: .success
        case .failed: .failure
        case .idle, .interrupted: .idle
        case .stale, .unknown: .unknown
        case .disconnected: .offline
        }
    }

    /// SF Symbol paired with every state so colour is never the only signal.
    static func symbol(_ state: SessionState) -> String {
        switch state {
        case .working: "circle.dotted"
        case .waitingUser, .waitingExternal: "exclamationmark.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .interrupted: "pause.circle"
        case .idle: "circle"
        case .stale: "clock.badge.questionmark"
        case .unknown: "questionmark.circle"
        case .disconnected: "bolt.horizontal.circle"
        }
    }

    // MARK: Activity

    func activity(_ activity: ActivityDescriptor?, session: AgentSession) -> String? {
        guard let activity else { return nil }
        let base: String
        switch activity.kind {
        case .thinking: base = tr("agent.activity.thinking", "Thinking")
        case .readingFiles: base = tr("agent.activity.readingFiles", "Reading files")
        case .searchingCode: base = tr("agent.activity.searchingCode", "Searching code")
        case .editingCode: base = tr("agent.activity.editingCode", "Editing code")
        case .runningCommand: base = tr("agent.activity.runningCommand", "Running a command")
        case .runningTests: base = tr("agent.activity.runningTests", "Running tests")
        case .building: base = tr("agent.activity.building", "Building")
        case .installingDependencies: base = tr("agent.activity.installing", "Installing dependencies")
        case .usingGit: base = tr("agent.activity.git", "Using Git")
        case .consultingWeb: base = tr("agent.activity.web", "Consulting the web")
        case .usingTool: base = tr("agent.activity.tool", "Using a tool")
        case .delegating: base = tr("agent.activity.delegating", "Working with subagents")
        case .planning: base = tr("agent.activity.planning", "Updating the plan")
        case .askingUser: base = tr("agent.activity.asking", "Asking you a question")
        case .awaitingPlanApproval: base = tr("agent.activity.planApproval", "Waiting for plan approval")
        case .compacting: base = tr("agent.activity.compacting", "Compacting context")
        }
        if let subagentID = activity.subagentID, let type = session.subagents[subagentID]?.type, activity.kind != .delegating {
            return "\(type) · \(base)"
        }
        return base
    }

    /// Short detail (command, file) shown after the activity, hidden in Privacy Mode.
    func activityDetail(_ activity: ActivityDescriptor?) -> String? {
        guard !privacyMode, let detail = activity?.detail, !detail.isEmpty else { return nil }
        return detail
    }

    // MARK: Attention

    func attention(_ request: AttentionRequest?) -> String {
        switch request?.info.kind {
        case .permission?: tr("agent.attention.permission", "Approval needed")
        case .question?: tr("agent.attention.question", "Question for you")
        case .planApproval?: tr("agent.attention.plan", "Plan ready for review")
        case .elicitation?: tr("agent.attention.elicitation", "Input requested by a tool")
        case .input?: tr("agent.attention.input", "Waiting for your input")
        default: tr("agent.attention.generic", "Needs your attention")
        }
    }

    func attentionDetail(_ request: AttentionRequest?) -> String? {
        guard !privacyMode, let request else { return nil }
        if let summary = request.info.summary, !summary.isEmpty {
            if let tool = request.info.toolName { return "\(tool): \(summary)" }
            return summary
        }
        return request.info.toolName
    }

    // MARK: Identity

    func project(_ info: ProjectInfo?) -> String {
        guard !privacyMode else { return tr("agent.privacy.project", "Project") }
        return info?.name ?? tr("agent.project.unknown", "Unknown project")
    }

    func path(_ path: String?) -> String? {
        guard !privacyMode else { return nil }
        return Formatting.shortPath(path)
    }

    func title(for session: AgentSession) -> String? {
        guard !privacyMode, let title = session.title, !title.isEmpty else { return nil }
        return title
    }

    func failure(_ record: FailureRecord?) -> String? {
        guard let record else { return nil }
        let base: String
        switch record.info.category {
        case .tests: base = tr("agent.failure.tests", "Tests failed")
        case .build: base = tr("agent.failure.build", "Build failed")
        case .api: base = apiError(record.info.code)
        case .tool: base = record.info.code == "interrupt" ? tr("agent.failure.interrupted", "Tool interrupted") : tr("agent.failure.tool", "Command failed")
        case .agent: base = tr("agent.failure.agent", "Turn failed")
        }
        return base
    }

    private func apiError(_ code: String?) -> String {
        switch code {
        case "rate_limit"?: tr("agent.failure.rateLimit", "Rate limit reached")
        case "overloaded"?: tr("agent.failure.overloaded", "Service overloaded")
        case "authentication_failed"?, "oauth_org_not_allowed"?: tr("agent.failure.auth", "Authentication failed")
        case "billing_error"?, "account_on_hold"?: tr("agent.failure.billing", "Billing problem")
        case "max_output_tokens"?: tr("agent.failure.maxTokens", "Response too long")
        default: tr("agent.failure.api", "API error")
        }
    }

    func provider(_ provider: AgentProvider) -> String { provider.displayName }

    func collection(_ method: CollectionMethod) -> String {
        switch method {
        case .claudeHook: tr("agent.source.claudeHook", "Claude Code hooks")
        case .codexHook: tr("agent.source.codexHook", "Codex hooks")
        case .codexNotify: tr("agent.source.codexNotify", "Codex notify (turn end only)")
        case .codexAppServer: tr("agent.source.codexAppServer", "Codex app-server (managed)")
        case .sessionRegistry: tr("agent.source.registry", "Claude Code session registry")
        case .reconciliation: tr("agent.source.reconciliation", "PulseDock reconciliation")
        case .fixture: tr("agent.source.demo", "Demo data")
        }
    }

    func confidence(_ confidence: Confidence) -> String {
        switch confidence {
        case .confirmed: tr("agent.confidence.confirmed", "Confirmed by the agent")
        case .inferred: tr("agent.confidence.inferred", "Inferred from other events")
        case .unknown: tr("agent.confidence.unknown", "Not verifiable")
        }
    }

    /// One-line status used by the island and the card: "Running tests", "Approval needed"…
    func headline(for presentation: SessionPresentation) -> String {
        let session = presentation.session
        if presentation.category == .attention { return attention(session.pendingAttention) }
        if let failure = presentation.transientFailure { return self.failure(failure) ?? state(.failed) }
        switch presentation.state {
        case .working:
            return activity(session.activity, session: session) ?? state(.working)
        case .failed:
            return failure(session.recentFailure) ?? state(.failed)
        case .completed:
            if session.backgroundTaskCount > 0 {
                return tr("agent.completed.background", "Turn finished · %ld in background", session.backgroundTaskCount)
            }
            return state(.completed)
        case .stale:
            if let quiet = presentation.quietFor {
                return tr("agent.stale.for", "No updates for %@", Formatting.duration(quiet))
            }
            return state(.stale)
        default:
            if session.lifecycle == .ended { return tr("agent.state.ended", "Session ended") }
            return state(presentation.state)
        }
    }
}
