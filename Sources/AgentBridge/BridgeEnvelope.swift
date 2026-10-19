import Foundation

/// One process in the ancestry of the hook helper (parent first).
public struct ProcessEntry: Codable, Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    /// Process start time in seconds since 1970 (detects PID reuse).
    public var start: Int64
    public var name: String
    public var path: String?

    public init(pid: Int32, ppid: Int32, start: Int64, name: String, path: String?) {
        self.pid = pid
        self.ppid = ppid
        self.start = start
        self.name = name
        self.path = path
    }
}

/// Where the hook ran: the process chain, the controlling terminal and a short whitelist
/// of environment identifiers (never the full environment).
public struct ProcessContext: Codable, Sendable, Hashable {
    public var chain: [ProcessEntry]
    public var tty: String?
    public var env: [String: String]

    public init(chain: [ProcessEntry], tty: String?, env: [String: String]) {
        self.chain = chain
        self.tty = tty
        self.env = env
    }

    /// Environment variables the helper may forward. All are identifiers, not secrets.
    public static let environmentWhitelist: [String] = [
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "TERM_SESSION_ID",
        "ITERM_SESSION_ID",
        "__CFBundleIdentifier",
        "TMUX_PANE",
        "WEZTERM_PANE",
        "KITTY_WINDOW_ID",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_PROJECT_DIR",
    ]
}

public struct HelperInfo: Codable, Sendable, Hashable {
    public var version: String
    public var pid: Int32

    public init(version: String, pid: Int32) {
        self.version = version
        self.pid = pid
    }
}

/// The message the hook helper sends over the local socket (one JSON object per line).
public struct BridgeEnvelope: Codable, Sendable, Hashable {
    public static let protocolVersion = 1

    public enum Kind: String, Codable, Sendable {
        /// A lifecycle hook (Claude Code or Codex).
        case hook
        /// Codex `notify` program invocation.
        case notify
        /// Developer and diagnostics messages (self-test, fixtures).
        case control
    }

    public enum Source: String, Codable, Sendable {
        case claudeCode = "claude_code"
        case codex
        case pulsedock
    }

    public var v: Int
    public var kind: Kind
    public var source: Source
    /// Hook event name (`PreToolUse`), notify type, or control command.
    public var event: String
    public var id: String
    /// Wall clock at helper start, milliseconds since 1970.
    public var ts: Int64
    /// Boot session identifier: monotonic times are comparable only within one boot.
    public var boot: String?
    /// Monotonic nanoseconds at helper start.
    public var mono: UInt64?
    /// Sanitized payload.
    public var payload: JSONValue
    public var ctx: ProcessContext?
    public var helper: HelperInfo

    public init(
        kind: Kind,
        source: Source,
        event: String,
        id: String = UUID().uuidString,
        ts: Int64,
        boot: String?,
        mono: UInt64?,
        payload: JSONValue,
        ctx: ProcessContext?,
        helper: HelperInfo
    ) {
        self.v = BridgeEnvelope.protocolVersion
        self.kind = kind
        self.source = source
        self.event = event
        self.id = id
        self.ts = ts
        self.boot = boot
        self.mono = mono
        self.payload = payload
        self.ctx = ctx
        self.helper = helper
    }

    public func encodedLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(line: Data) throws -> BridgeEnvelope {
        try JSONDecoder().decode(BridgeEnvelope.self, from: line)
    }

    /// Basic structural validation applied by the server before anything else.
    public func validate() throws {
        guard v >= 1, v <= BridgeEnvelope.protocolVersion else { throw BridgeError.unsupportedVersion(v) }
        guard !event.isEmpty, event.count <= 64 else { throw BridgeError.invalid("event") }
        guard !id.isEmpty, id.count <= 64 else { throw BridgeError.invalid("id") }
        guard ts > 0 else { throw BridgeError.invalid("ts") }
        if let ctx, ctx.chain.count > 16 || ctx.env.count > 32 { throw BridgeError.invalid("ctx") }
    }
}

public enum BridgeError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case invalid(String)
    case tooLarge(Int)
    case socket(String, Int32)
    case alreadyRunning
    case insecureDirectory(String)

    public var description: String {
        switch self {
        case let .unsupportedVersion(version): "unsupported protocol version \(version)"
        case let .invalid(field): "invalid field \(field)"
        case let .tooLarge(size): "message too large (\(size) bytes)"
        case let .socket(operation, code): "\(operation) failed: \(String(cString: strerror(code)))"
        case .alreadyRunning: "another PulseDock instance is listening"
        case let .insecureDirectory(path): "refusing insecure directory \(path)"
        }
    }
}
