import Foundation

/// Removes credentials from short strings (commands, URLs, messages) before they leave the
/// hook helper. Patterns err on the side of redacting.
public enum SecretRedactor {
    public static let placeholder = "[REDACTED]"

    private struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        let patterns: [(String, String)] = [
            // Authorization headers.
            (#"(?i)(authorization:\s*(?:bearer|basic|token)\s+)[^\s'"]+"#, "$1\(placeholder)"),
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{12,}"#, "$1\(placeholder)"),
            // Credentials embedded in URLs.
            (#"(?i)([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1\(placeholder)@"),
            // key=value and key: value assignments for sensitive names.
            (#"(?i)\b([A-Z0-9_]*(?:api[_-]?key|token|secret|passw(?:or)?d|pwd|credential|private[_-]?key|access[_-]?key|session[_-]?key)[A-Z0-9_]*)\s*([=:])\s*("[^"]*"|'[^']*'|[^\s'"&;|]+)"#, "$1$2\(placeholder)"),
            // CLI flags carrying secrets.
            (#"(?i)(--?(?:password|passwd|token|api-?key|secret|auth(?:-token)?|access-key|client-secret)(?:=|\s+))("[^"]*"|'[^']*'|[^\s]+)"#, "$1\(placeholder)"),
            // Well-known token formats.
            (#"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}"#, placeholder),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, placeholder),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, placeholder),
            (#"\bglpat-[A-Za-z0-9_-]{16,}"#, placeholder),
            (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, placeholder),
            (#"\bAKIA[0-9A-Z]{16}\b"#, placeholder),
            (#"\bAIza[0-9A-Za-z_-]{30,}"#, placeholder),
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, placeholder),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, placeholder),
            // Long opaque blobs that mix letters and digits (40+ chars).
            (#"\b(?=[A-Za-z0-9_\-+/]*[0-9])(?=[A-Za-z0-9_\-+/]*[A-Za-z])[A-Za-z0-9_\-+/]{40,}={0,2}"#, placeholder),
        ]
        return patterns.compactMap { pattern, template in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Rule(expression: expression, template: template)
        }
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.expression.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.template)
        }
        return result
    }

    /// Redacts, collapses whitespace and truncates to `maxLength` characters.
    public static func clean(_ text: String, maxLength: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: { $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
        let redacted = redact(collapsed).trimmingCharacters(in: .whitespaces)
        guard redacted.count > maxLength else { return redacted }
        return String(redacted.prefix(max(1, maxLength - 1))) + "…"
    }

    /// First line only, redacted and truncated (used for error strings that may be followed
    /// by command output).
    public static func firstLine(_ text: String, maxLength: Int) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return clean(line, maxLength: maxLength)
    }
}
