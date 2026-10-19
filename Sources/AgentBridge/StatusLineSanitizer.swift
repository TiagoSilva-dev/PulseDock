import Foundation

/// Whitelist sanitization of Claude Code's status line input
/// (`code.claude.com/docs/en/statusline`), performed inside the helper.
///
/// Only usage numbers survive: rate-limit windows (Pro/Max), session cost estimate, context
/// window use, model and the project folder. Session titles (AI-generated from the
/// conversation), transcript paths, PR links, repository and worktree names are dropped.
public enum StatusLineSanitizer {
    public static func sanitize(_ input: [String: Any]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        if let id = string(input["session_id"], limit: 160) { out["session_id"] = .string(id) }
        if let version = string(input["version"], limit: 32) { out["version"] = .string(version) }
        let workspace = input["workspace"] as? [String: Any]
        if let folder = string(workspace?["project_dir"], limit: 1024) ?? string(input["cwd"], limit: 1024) {
            out["project_dir"] = .string(folder)
        }
        if let model = input["model"] as? [String: Any] {
            var m: [String: JSONValue] = [:]
            if let id = string(model["id"], limit: 80) { m["id"] = .string(id) }
            if let name = string(model["display_name"], limit: 64) { m["display_name"] = .string(name) }
            if !m.isEmpty { out["model"] = .object(m) }
        }
        if let cost = numbers(input["cost"], ["total_cost_usd", "total_duration_ms", "total_api_duration_ms", "total_lines_added", "total_lines_removed"]) {
            out["cost"] = cost
        }
        if let context = numbers(input["context_window"], ["used_percentage", "context_window_size", "total_input_tokens", "total_output_tokens"]) {
            out["context_window"] = context
        }
        if let exceeds = input["exceeds_200k_tokens"] as? Bool { out["exceeds_200k_tokens"] = .bool(exceeds) }
        if let effort = (input["effort"] as? [String: Any])?["level"] as? String, ["low", "medium", "high", "xhigh", "max"].contains(effort) {
            out["effort"] = .string(effort)
        }
        if let limits = input["rate_limits"] as? [String: Any] {
            var l: [String: JSONValue] = [:]
            for window in ["five_hour", "seven_day"] {
                if let value = numbers(limits[window], ["used_percentage", "resets_at"]) { l[window] = value }
            }
            if case var .object(spend)? = numbers(limits["spend_limit"], ["used_percentage", "resets_at", "used_usd", "limit_usd"]) {
                if let period = (limits["spend_limit"] as? [String: Any])?["period"] as? String, ["daily", "weekly", "monthly"].contains(period) {
                    spend["period"] = .string(period)
                }
                l["spend_limit"] = .object(spend)
            }
            if !l.isEmpty { out["rate_limits"] = .object(l) }
        }
        return .object(out)
    }

    static func string(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    /// Finite, non-negative numbers only (`null` early in a session is simply absent).
    static func numbers(_ value: Any?, _ keys: [String]) -> JSONValue? {
        guard let object = value as? [String: Any] else { return nil }
        var out: [String: JSONValue] = [:]
        for key in keys {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let double = number.doubleValue
            guard double.isFinite, double >= 0, double < 1e15 else { continue }
            out[key] = .number(double)
        }
        return out.isEmpty ? nil : .object(out)
    }

    /// The compact line the helper prints when the user had no status line of their own:
    /// `Opus · ctx 8% · 5h 23% · 7d 41%`. Language-neutral so it needs no localization.
    public static func compactLine(_ sanitized: JSONValue) -> String {
        var parts: [String] = []
        if let name = sanitized["model"]?["display_name"]?.stringValue { parts.append(name) }
        if let context = sanitized["context_window"]?["used_percentage"]?.numberValue { parts.append("ctx \(Int(context.rounded()))%") }
        if let five = sanitized["rate_limits"]?["five_hour"]?["used_percentage"]?.numberValue { parts.append("5h \(Int(five.rounded()))%") }
        if let seven = sanitized["rate_limits"]?["seven_day"]?["used_percentage"]?.numberValue { parts.append("7d \(Int(seven.rounded()))%") }
        if let spend = sanitized["rate_limits"]?["spend_limit"]?["used_percentage"]?.numberValue { parts.append("spend \(Int(spend.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}
