import AgentBridge
import AgentCore
import Foundation

/// Reads Claude Code's local session registry (`~/.claude/sessions/<pid>.json`).
///
/// This file format is not documented, so PulseDock uses it only for **discovery and
/// liveness**: which sessions exist, their process, directory and name. It never derives
/// a state from it. Files ending in `.key` are never opened.
public final class ClaudeSessionRegistry: @unchecked Sendable {
    public struct Entry: Sendable, Hashable {
        public var pid: Int32
        public var sessionID: String
        public var cwd: String?
        public var startedAt: Date?
        public var updatedAt: Date?
        public var name: String?
        public var kind: String?
        public var entrypoint: String?
        public var version: String?
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "app.pulsedock.claude-registry", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var pendingScan: DispatchWorkItem?
    private let onChange: @Sendable ([Entry]) -> Void

    public init(directory: URL = ClaudeCodeDetector.sessionsDirectory, onChange: @escaping @Sendable ([Entry]) -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    /// Starts watching the directory (vnode events, no polling) and performs an initial scan.
    public func start() {
        queue.async { [weak self] in
            guard let self, self.source == nil else { return }
            self.scheduleScan(delay: 0)
            let fd = open(self.directory.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: self.queue)
            source.setEventHandler { [weak self] in self?.scheduleScan(delay: 0.25) }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            self?.pendingScan?.cancel()
        }
    }

    /// Forces a scan (used by periodic liveness reconciliation).
    public func refresh() {
        queue.async { [weak self] in self?.scheduleScan(delay: 0) }
    }

    private func scheduleScan(delay: TimeInterval) {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onChange(ClaudeSessionRegistry.scan(directory: self.directory))
        }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Entries whose process is still running.
    public static func scan(directory: URL) -> [Entry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Entry? in
                guard let data = try? Data(contentsOf: url), data.count < 65_536 else { return nil }
                return parse(data)
            }
            .filter(isLive)
    }

    /// The process must exist and must not have started after the session (PID reuse).
    static func isLive(_ entry: Entry) -> Bool {
        guard let info = ProcessInspector.info(pid: entry.pid) else { return false }
        if let startedAt = entry.startedAt, Double(info.start) > startedAt.timeIntervalSince1970 + 5 { return false }
        return true
    }

    public static func parse(_ data: Data) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { return nil }
        func date(_ key: String) -> Date? {
            (object[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        return Entry(
            pid: pid,
            sessionID: sessionID,
            cwd: object["cwd"] as? String,
            startedAt: date("startedAt"),
            updatedAt: date("updatedAt"),
            name: (object["name"] as? String).map { String($0.prefix(80)) },
            kind: object["kind"] as? String,
            entrypoint: object["entrypoint"] as? String,
            version: object["version"] as? String
        )
    }

    /// Discovery event for an entry (no state information, confidence `.inferred`).
    public static func discoveryEvent(for entry: Entry, receivedAt: Date = Date()) -> AgentEvent {
        let evidence = entry.updatedAt ?? entry.startedAt ?? receivedAt
        let start = ProcessInspector.info(pid: entry.pid)?.start
        var metadata: [String: String] = [:]
        if let name = entry.name { metadata["session_title"] = name }
        if let version = entry.version { metadata["agent_version"] = version }
        return AgentEvent(
            id: "registry-\(entry.sessionID)-\(Int64(evidence.timeIntervalSince1970 * 1000))",
            provider: .claudeCode,
            sessionID: entry.sessionID,
            kind: .sessionDiscovered,
            receivedAt: receivedAt,
            order: EventOrder(date: evidence),
            collection: .sessionRegistry,
            confidence: .inferred,
            projectPath: entry.cwd,
            sourceEvent: "registry",
            origin: SessionOrigin(agentPID: entry.pid, agentStartTime: start, entrypoint: entry.entrypoint),
            metadata: metadata
        )
    }
}
