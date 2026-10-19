import AgentCore
import CodexAdapter
import Diagnostics
import Foundation
import Observation

/// Managed Mode: Codex tasks started from PulseDock through the official app-server. These
/// are the only sessions where PulseDock may answer approvals or interrupt a turn, because
/// the app-server protocol provides those operations.
@Observable
final class CodexManagedService {
    enum State: Equatable {
        case unavailable(String)
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var state: State = .stopped
    /// Session id → (thread id, active turn id) for sessions this service owns.
    private(set) var threads: [String: (thread: String, turn: String?)] = [:]

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored private var client: CodexAppServerClient?
    @ObservationIgnored var executablePath: () -> String? = { nil }

    init(store: AgentStore) {
        self.store = store
    }

    func owns(_ key: SessionKey) -> Bool {
        key.provider == .codex && threads[key.sessionID] != nil
    }

    /// Starts a new Codex thread in `projectPath` and submits `prompt` as its first turn.
    func startTask(projectPath: String, prompt: String) async throws {
        let client = try await runningClient()
        let threadID = try await client.startThread(cwd: projectPath)
        threads[threadID] = (threadID, nil)
        let turnID = try await client.startTurn(threadID: threadID, text: prompt)
        threads[threadID] = (threadID, turnID)
    }

    /// Answers a pending approval with one of the decisions the server offered.
    func respond(to request: AttentionRequest, in session: AgentSession, decision: String) throws {
        guard owns(session.key), let requestID = request.info.requestID, let client else {
            throw CodexAppServerClient.ClientError.notRunning
        }
        guard request.info.availableDecisions.contains(decision) else { throw CodexAppServerClient.ClientError.invalidResponse }
        try client.respond(toRequest: requestID, decision: decision)
    }

    func interrupt(_ session: AgentSession) async throws {
        guard let entry = threads[session.sessionID], let client else { throw CodexAppServerClient.ClientError.notRunning }
        let turnID = session.currentTurn?.id ?? entry.turn
        guard let turnID else { return }
        try await client.interrupt(threadID: entry.thread, turnID: turnID)
    }

    func stop() {
        client?.stop()
        client = nil
        state = .stopped
    }

    private func runningClient() async throws -> CodexAppServerClient {
        if let client, client.isRunning { return client }
        guard let path = executablePath() else {
            state = .unavailable(tr("codex.managed.notFound", "Codex CLI was not found on this Mac."))
            throw CodexAppServerClient.ClientError.launchFailed("codex not found")
        }
        state = .starting
        let environment = await ShellEnvironment.resolved()
        let store = self.store
        let client = CodexAppServerClient(
            configuration: .init(executable: URL(fileURLWithPath: path), environment: environment),
            onEvents: { events in Task { @MainActor in store.ingest(events) } },
            onTermination: { [weak self] status in
                Task { @MainActor in
                    self?.state = status == 0 ? .stopped : .failed(tr("codex.managed.exited", "Codex app-server exited (status %ld).", Int(status)))
                    self?.client = nil
                }
            }
        )
        do {
            try await client.start()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
        self.client = client
        state = .running
        return client
    }
}

/// The user's login-shell environment (PATH in particular), so tools started by managed
/// agents find the same programs as in a terminal. Only a small set of variables is kept.
nonisolated enum ShellEnvironment {
    static let keptVariables = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR", "CODEX_HOME", "SSH_AUTH_SOCK"]

    static func resolved() async -> [String: String] {
        await Task.detached(priority: .userInitiated) {
            var environment = ProcessInfo.processInfo.environment.filter { keptVariables.contains($0.key) }
            let shell = environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", "printf '%s' \"$PATH\""]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < deadline { usleep(20_000) }
                if process.isRunning { process.terminate() }
                let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if !path.isEmpty, path.contains("/") { environment["PATH"] = path }
            }
            if environment["PATH"] == nil { environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
            return environment
        }.value
    }
}
