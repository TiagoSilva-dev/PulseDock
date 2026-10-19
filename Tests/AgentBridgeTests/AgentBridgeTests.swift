@testable import AgentBridge
import Foundation
import Synchronization
import Testing

@Suite("Agent bridge: socket, sanitizer, redaction, spool")
struct AgentBridgeTests {
    func temporaryDirectory() throws -> URL {
        // Short path: Unix socket paths are limited to 104 bytes.
        let url = URL(fileURLWithPath: "/tmp/pd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func envelope(event: String = "PreToolUse", payload: JSONValue = .object(["session_id": .string("s1")])) -> BridgeEnvelope {
        BridgeEnvelope(kind: .hook, source: .claudeCode, event: event, ts: 1_800_000_000_000, boot: "b", mono: 1,
                       payload: payload, ctx: nil, helper: HelperInfo(version: "test", pid: 1))
    }

    @Test("Envelopes travel through the Unix socket and are validated")
    func socketRoundTrip() async throws {
        let directory = try temporaryDirectory()
        let socket = directory.appendingPathComponent("b.sock").path
        let received = Mutex<[BridgeEnvelope]>([])
        let server = BridgeServer(socketPath: socket) { envelope in
            received.withLock { $0.append(envelope) }
        }
        try server.start()
        defer { server.stop() }

        // Socket and directory are private to the user.
        var info = stat()
        stat(socket, &info)
        #expect(info.st_mode & 0o077 == 0)

        for index in 0..<5 {
            let outcome = BridgeClient.send(try envelope(event: "Event\(index)").encodedLine(), socketPath: socket)
            #expect(outcome == .delivered)
        }
        // A line that is not a valid envelope is counted and dropped.
        _ = BridgeClient.send(Data("not json\n".utf8), socketPath: socket)

        for _ in 0..<100 where received.withLock({ $0.count }) < 5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received.withLock { $0.map(\.event) } == (0..<5).map { "Event\($0)" })
        #expect(server.statistics.invalidMessages == 1)
        #expect(server.statistics.accepted == 5)
    }

    @Test("Oversized messages are dropped; a second server refuses to steal the socket")
    func limits() async throws {
        let directory = try temporaryDirectory()
        let socket = directory.appendingPathComponent("b.sock").path
        let count = Mutex(0)
        let server = BridgeServer(socketPath: socket, maxMessageBytes: 1024) { _ in count.withLock { $0 += 1 } }
        try server.start()
        defer { server.stop() }
        var big = try envelope(payload: .object(["session_id": .string("s"), "x": .string(String(repeating: "a", count: 5000))])).encodedLine()
        big.append(contentsOf: Data("\n".utf8))
        _ = BridgeClient.send(big, socketPath: socket)
        try await Task.sleep(for: .milliseconds(100))
        #expect(count.withLock { $0 } == 0)
        #expect(server.statistics.oversized == 1)

        let second = BridgeServer(socketPath: socket) { _ in }
        #expect(throws: BridgeError.alreadyRunning) { try second.start() }
    }

    @Test("Without a listener the client reports unavailable quickly")
    func unavailable() throws {
        let start = Date()
        let outcome = BridgeClient.send(Data("x\n".utf8), socketPath: "/tmp/pd-missing-\(UUID().uuidString.prefix(6)).sock")
        #expect(outcome == .unavailable)
        #expect(Date().timeIntervalSince(start) < 0.1)
    }

    @Test("Spool appends privately and drains atomically")
    func spool() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("run/spool.jsonl")
        #expect(BridgeSpool.append(Data("a\n".utf8), to: url))
        #expect(BridgeSpool.append(Data("b\n".utf8), to: url))
        var info = stat()
        stat(url.path, &info)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(BridgeSpool.drain(from: url).map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
        #expect(BridgeSpool.drain(from: url).isEmpty)
    }

    @Test("Credentials are redacted from commands, URLs and messages")
    func redaction() {
        let cases: [(String, String)] = [
            ("curl -H 'Authorization: Bearer abc.def.ghi' https://api", "Authorization: Bearer [REDACTED]"),
            ("git clone https://user:hunter2@github.com/x/y", "https://[REDACTED]@github.com"),
            ("export OPENAI_API_KEY=sk-proj-abcdefghijklmnop1234", "OPENAI_API_KEY=[REDACTED]"),
            ("mysql --password=hunter2 -u root", "--password=[REDACTED]"),
            ("echo ghp_abcdefghijklmnopqrstuvwxyz0123456789", "echo [REDACTED]"),
            ("aws s3 ls # AKIAABCDEFGHIJKLMNOP", "# [REDACTED]"),
        ]
        for (input, fragment) in cases {
            let output = SecretRedactor.redact(input)
            #expect(output.contains(fragment), "\(input) → \(output)")
            #expect(!output.contains("hunter2"))
        }
        #expect(SecretRedactor.redact("swift test --filter Foo") == "swift test --filter Foo")
        #expect(SecretRedactor.redact("git checkout 3f2a1b9") == "git checkout 3f2a1b9")
    }

    @Test("Codex apply_patch keeps only file names; argv commands are joined")
    func codexToolInputs() {
        let patch = "*** Begin Patch\n*** Update File: src/a.rs\n@@\n- secret line\n+ new secret\n*** Add File: src/b.rs\n+ content\n*** End Patch"
        let sanitized = HookSanitizer.sanitizeToolInput(toolName: "apply_patch", input: ["command": patch], options: SanitizerOptions())
        #expect(sanitized["files"]?.arrayValue?.compactMap(\.stringValue) == ["src/a.rs", "src/b.rs"])
        #expect(!sanitized.canonicalString.contains("secret"))
        #expect(HookSanitizer.commandString(["bash", "-lc", "npm test"]) == "npm test")
        #expect(HookSanitizer.exitCode(inText: #"{"output":"…","metadata":{"exit_code":2,"duration_seconds":0.4}}"#) == 2)
        #expect(HookSanitizer.exitCode(inText: "Process exited with code 1\nOutput: …") == 1)
    }

    @Test("Command detail levels")
    func commandDetail() {
        #expect(HookSanitizer.sanitizeCommand("TOKEN=abc npm test -- --watch", detail: .program) == "npm test")
        #expect(HookSanitizer.sanitizeCommand("npm test", detail: .none) == "")
        #expect(HookSanitizer.sanitizeURL("https://user:pw@example.com/path?token=1#frag") == "https://example.com/path")
        #expect(HookSanitizer.slashCommand("/review the diff") == "/review")
        #expect(HookSanitizer.slashCommand("please /review") == nil)
    }

    @Test("Envelope validation rejects malformed input")
    func validation() throws {
        var bad = envelope()
        bad.v = 99
        #expect(throws: BridgeError.unsupportedVersion(99)) { try bad.validate() }
        bad = envelope(event: String(repeating: "x", count: 100))
        #expect(throws: BridgeError.self) { try bad.validate() }
        try envelope().validate()
    }

    @Test("Process inspection reaches this process's ancestors")
    func processContext() {
        let context = ProcessInspector.captureContext()
        #expect(!context.chain.isEmpty)
        #expect(context.chain.first?.pid == getppid())
        #expect(ProcessInspector.isAlive(pid: getpid(), start: nil))
        #expect(!ProcessInspector.isAlive(pid: getpid(), start: 1))
    }
}
