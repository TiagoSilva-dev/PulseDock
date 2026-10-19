import AgentBridge
import AgentCore
import ClaudeCodeAdapter
import CodexAdapter
import Diagnostics
import Foundation
import Observation

/// Receives hook envelopes on the local socket, normalises them with the provider adapters
/// and hands the events to the `AgentStore` on the main actor.
@Observable
final class AgentBridgeService {
    enum Status: Equatable {
        case stopped
        case listening
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private(set) var lastSelfTestAt: Date?
    private(set) var helperInstalled = false

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored private var server: BridgeServer?
    @ObservationIgnored private var registry: ClaudeSessionRegistry?
    /// Developer control messages (snapshots), enabled only with `--developer`.
    @ObservationIgnored var onControl: (String, JSONValue) -> Void = { _, _ in }
    /// Claude Code status line snapshots (Claude Usage widget).
    @ObservationIgnored var onUsage: (ClaudeUsageSnapshot) -> Void = { _ in }

    init(store: AgentStore) {
        self.store = store
    }

    var statistics: BridgeServer.Statistics? { server?.statistics }

    func start(useRegistry: Bool) {
        deployHelper()
        let store = self.store
        let server = BridgeServer { [weak self] envelope in
            // Runs on the bridge queue: normalisation is pure and cheap.
            let received = Date()
            if envelope.kind == .statusLine {
                guard let snapshot = ClaudeUsageNormalizer.snapshot(from: envelope, receivedAt: received) else { return }
                Task { @MainActor in self?.onUsage(snapshot) }
                return
            }
            let events: [AgentEvent]
            switch envelope.source {
            case .claudeCode: events = ClaudeCodeNormalizer.normalize(envelope, receivedAt: received)
            case .codex: events = CodexNormalizer.normalize(envelope, receivedAt: received)
            case .pulsedock: events = []
            }
            let control = envelope.kind == .control ? (envelope.event, envelope.payload) : nil
            Task { @MainActor in
                if let control {
                    self?.handleControl(control.0, payload: control.1)
                } else {
                    store.ingest(events)
                }
            }
        }
        do {
            try server.start()
            self.server = server
            status = .listening
            PulseLog.bridge.info("Bridge listening")
            // Events that arrived while PulseDock was not running.
            let spooled = BridgeSpool.drain()
            if !spooled.isEmpty {
                PulseLog.bridge.info("Replaying \(spooled.count, privacy: .public) spooled events")
                server.replay(spooled)
            }
        } catch {
            status = .failed(String(describing: error))
            PulseLog.bridge.error("Bridge failed to start: \(String(describing: error), privacy: .public)")
            DiagnosticsRecorder.shared.record(.error, "bridge", "start failed: \(error)")
        }
        setRegistry(enabled: useRegistry)
    }

    func stop() {
        server?.stop()
        server = nil
        registry?.stop()
        registry = nil
        status = .stopped
    }

    func setRegistry(enabled: Bool) {
        if enabled, registry == nil {
            let store = self.store
            let registry = ClaudeSessionRegistry { entries in
                let converted = entries.map { ClaudeRegistryEntry(sessionID: $0.sessionID, event: ClaudeSessionRegistry.discoveryEvent(for: $0)) }
                Task { @MainActor in store.applyRegistry(converted) }
            }
            registry.start()
            self.registry = registry
        } else if !enabled {
            registry?.stop()
            registry = nil
        }
    }

    func refreshRegistry() { registry?.refresh() }

    private func handleControl(_ event: String, payload: JSONValue) {
        switch event {
        case "self-test":
            lastSelfTestAt = Date()
            DiagnosticsRecorder.shared.record(.info, "bridge", "self-test received")
        case "ping":
            DiagnosticsRecorder.shared.record(.info, "bridge", "ping received")
        default:
            onControl(event, payload)
        }
    }

    // MARK: Helper deployment

    /// Copies the helper from the app bundle to a stable location referenced by the agent
    /// hooks, so hooks keep working when the app is moved or updated.
    func deployHelper() {
        guard let bundled = Self.bundledHelperURL else {
            helperInstalled = FileManager.default.isExecutableFile(atPath: BridgePaths.installedHelper.path)
            return
        }
        let destination = BridgePaths.installedHelper
        do {
            try BridgePaths.ensurePrivateDirectory(BridgePaths.supportDirectory)
            try FileManager.default.createDirectory(at: BridgePaths.binDirectory, withIntermediateDirectories: true)
            if !FileManager.default.contentsEqual(atPath: bundled.path, andPath: destination.path) {
                let temporary = destination.appendingPathExtension("new")
                try? FileManager.default.removeItem(at: temporary)
                try FileManager.default.copyItem(at: bundled, to: temporary)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
                if rename(temporary.path, destination.path) != 0 {
                    throw CocoaError(.fileWriteUnknown)
                }
                PulseLog.bridge.info("Hook helper deployed")
            }
            helperInstalled = true
        } catch {
            helperInstalled = FileManager.default.isExecutableFile(atPath: destination.path)
            PulseLog.bridge.error("Helper deployment failed: \(String(describing: error), privacy: .public)")
        }
    }

    static var bundledHelperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pulsedock-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Runs the deployed helper in self-test mode and waits for its message to come back
    /// through the socket: proves the whole helper → socket → app path works.
    func runSelfTest() async -> Bool {
        let before = lastSelfTestAt
        let helper = BridgePaths.installedHelper
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return false }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--self-test"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            if lastSelfTestAt != before { return true }
        }
        return false
    }
}
