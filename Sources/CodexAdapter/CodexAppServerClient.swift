import AgentBridge
import AgentCore
import Diagnostics
import Foundation

/// Managed Mode: a `codex app-server` child process driven over JSON-RPC (stdio, JSONL).
///
/// Only sessions started through this client are visible; the app-server does not expose
/// independent `codex` processes. Approvals are answered only by explicit user action
/// through `respond(toRequest:decision:)`; nothing is approved automatically.
public final class CodexAppServerClient: @unchecked Sendable {
    public enum ClientError: Error, LocalizedError, Equatable {
        case notRunning
        case launchFailed(String)
        case rpc(code: Int, message: String)
        case timeout
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .notRunning: "Codex app-server is not running."
            case let .launchFailed(message): "Could not start Codex app-server: \(message)"
            case let .rpc(code, message): "Codex returned an error (\(code)): \(message)"
            case .timeout: "Codex app-server did not answer in time."
            case .invalidResponse: "Codex app-server sent an unexpected response."
            }
        }
    }

    public struct Configuration: Sendable {
        public var executable: URL
        public var environment: [String: String]
        public var clientName: String
        public var clientVersion: String

        public init(executable: URL, environment: [String: String], clientName: String = "pulsedock", clientVersion: String = "0.1.0") {
            self.executable = executable
            self.environment = environment
            self.clientName = clientName
            self.clientVersion = clientVersion
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "app.pulsedock.codex-app-server")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: @Sendable (Result<JSONValue, ClientError>) -> Void] = [:]
    private var serverRequestIDs: [String: JSONValue] = [:]
    private var mapper = CodexAppServerMapper()
    private let onEvents: @Sendable ([AgentEvent]) -> Void
    private let onTermination: @Sendable (Int32) -> Void

    public init(
        configuration: Configuration,
        onEvents: @escaping @Sendable ([AgentEvent]) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.onEvents = onEvents
        self.onTermination = onTermination
    }

    public var isRunning: Bool { queue.sync { process?.isRunning == true } }

    // MARK: Lifecycle

    public func start() async throws {
        try queue.sync {
            guard process == nil else { return }
            let process = Process()
            process.executableURL = configuration.executable
            process.arguments = ["app-server"]
            process.environment = configuration.environment
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] finished in
                self?.handleTermination(status: finished.terminationStatus)
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                self.queue.async { self.receive(data) }
            }
            do {
                try process.run()
            } catch {
                throw ClientError.launchFailed(error.localizedDescription)
            }
            self.process = process
            self.input = stdinPipe.fileHandleForWriting
        }
        _ = try await request("initialize", params: .object([
            "clientInfo": .object([
                "name": .string(configuration.clientName),
                "title": .string("PulseDock"),
                "version": .string(configuration.clientVersion),
            ]),
        ]))
        try notify("initialized", params: .object([:]))
        PulseLog.integrations.info("Codex app-server initialised")
    }

    public func stop() {
        queue.sync {
            process?.terminate()
            failPending(.notRunning)
            process = nil
            input = nil
        }
    }

    // MARK: Threads and turns

    /// Starts a thread in `cwd`. Sandbox and approval policy follow the user's Codex
    /// configuration unless explicitly overridden.
    public func startThread(cwd: String, model: String? = nil) async throws -> String {
        var params: [String: JSONValue] = ["cwd": .string(cwd), "serviceName": .string("pulsedock")]
        if let model { params["model"] = .string(model) }
        let result = try await request("thread/start", params: .object(params))
        guard let thread = result["thread"], let id = thread["id"]?.stringValue else { throw ClientError.invalidResponse }
        let sessionID = thread["sessionId"]?.stringValue
        queue.sync { mapper.register(threadID: id, sessionID: sessionID) }
        return id
    }

    public func startTurn(threadID: String, text: String) async throws -> String {
        let result = try await request("turn/start", params: .object([
            "threadId": .string(threadID),
            "input": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]))
        guard let id = result["turn"]?["id"]?.stringValue else { throw ClientError.invalidResponse }
        return id
    }

    public func interrupt(threadID: String, turnID: String) async throws {
        _ = try await request("turn/interrupt", params: .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
    }

    /// Answers a pending server request (approval) with a decision the server offered.
    public func respond(toRequest requestID: String, decision: String) throws {
        try queue.sync {
            guard let originalID = serverRequestIDs.removeValue(forKey: requestID) else { throw ClientError.invalidResponse }
            try write(.object(["id": originalID, "result": .object(["decision": .string(decision)])]))
        }
    }

    // MARK: JSON-RPC plumbing

    private func request(_ method: String, params: JSONValue, timeout: TimeInterval = 60) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            queue.async { [self] in
                guard process?.isRunning == true else {
                    continuation.resume(throwing: ClientError.notRunning)
                    return
                }
                let id = nextID
                nextID += 1
                pending[id] = { result in
                    switch result {
                    case let .success(value): continuation.resume(returning: value)
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                }
                do {
                    try write(.object(["id": .number(Double(id)), "method": .string(method), "params": params]))
                } catch {
                    pending.removeValue(forKey: id)?(.failure(.notRunning))
                    return
                }
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    pending.removeValue(forKey: id)?(.failure(.timeout))
                }
            }
        }
    }

    private func notify(_ method: String, params: JSONValue) throws {
        try queue.sync { try write(.object(["method": .string(method), "params": params])) }
    }

    /// Runs on `queue`.
    private func write(_ message: JSONValue) throws {
        guard let input else { throw ClientError.notRunning }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            handle(object)
        }
        if buffer.count > 8 * 1024 * 1024 { buffer.removeAll() }
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        let id = message["id"]
        if method == nil, let numericID = (id as? NSNumber)?.intValue {
            let callback = pending.removeValue(forKey: numericID)
            if let error = message["error"] as? [String: Any] {
                callback?(.failure(.rpc(code: (error["code"] as? Int) ?? -1, message: (error["message"] as? String) ?? "")))
            } else {
                callback?(.success(JSONValue(any: message["result"])))
            }
            return
        }
        guard let method else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        let events: [AgentEvent]
        if let id {
            let key = CodexAppServerMapper.requestKey(id)
            serverRequestIDs[key] = JSONValue(any: id)
            events = mapper.events(forServerRequest: method, requestID: key, params: params)
        } else {
            events = mapper.events(forNotification: method, params: params)
        }
        if !events.isEmpty { onEvents(events) }
    }

    private func handleTermination(status: Int32) {
        queue.async { [self] in
            failPending(.notRunning)
            process = nil
            input = nil
            onTermination(status)
        }
    }

    private func failPending(_ error: ClientError) {
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
    }
}
