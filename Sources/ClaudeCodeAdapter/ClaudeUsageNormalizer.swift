import AgentBridge
import AgentCore
import Foundation

/// Status line envelope (already sanitized by the helper) → usage snapshot.
public enum ClaudeUsageNormalizer {
    public static func snapshot(from envelope: BridgeEnvelope, receivedAt: Date = Date()) -> ClaudeUsageSnapshot? {
        guard envelope.kind == .statusLine, envelope.source == .claudeCode else { return nil }
        let payload = envelope.payload
        guard let sessionID = payload["session_id"]?.stringValue, !sessionID.isEmpty else { return nil }
        let observed = Date(timeIntervalSince1970: Double(envelope.ts) / 1000)
        func window(_ name: String) -> UsageWindow? {
            guard let object = payload["rate_limits"]?[name],
                  let percent = object["used_percentage"]?.numberValue,
                  let reset = object["resets_at"]?.numberValue else { return nil }
            return UsageWindow(usedPercent: min(100, percent), resetsAt: Date(timeIntervalSince1970: reset))
        }
        var spend: SpendWindow?
        if let object = payload["rate_limits"]?["spend_limit"], let percent = object["used_percentage"]?.numberValue {
            spend = SpendWindow(usedPercent: percent, resetsAt: object["resets_at"]?.numberValue.map { Date(timeIntervalSince1970: $0) },
                                usedUSD: object["used_usd"]?.numberValue, limitUSD: object["limit_usd"]?.numberValue,
                                period: object["period"]?.stringValue)
        }
        let cost = payload["cost"]
        let context = payload["context_window"]
        return ClaudeUsageSnapshot(
            sessionID: sessionID,
            // The helper's clock, unless it is implausibly far from ours.
            observedAt: abs(observed.timeIntervalSince(receivedAt)) < 300 ? observed : receivedAt,
            modelID: payload["model"]?["id"]?.stringValue,
            modelName: payload["model"]?["display_name"]?.stringValue,
            projectPath: payload["project_dir"]?.stringValue,
            version: payload["version"]?.stringValue,
            costUSD: cost?["total_cost_usd"]?.numberValue,
            durationMS: cost?["total_duration_ms"]?.numberValue,
            linesAdded: cost?["total_lines_added"]?.intValue,
            linesRemoved: cost?["total_lines_removed"]?.intValue,
            contextUsedPercent: context?["used_percentage"]?.numberValue,
            contextSize: context?["context_window_size"]?.intValue,
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            spend: spend
        )
    }
}
