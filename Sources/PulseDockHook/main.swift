import AgentBridge
import Darwin
import Foundation

// pulsedock-hook — invoked by Claude Code and Codex hooks.
//
//   pulsedock-hook claude-code [EventName]    hook JSON on stdin
//   pulsedock-hook codex [EventName]          hook JSON on stdin
//   pulsedock-hook codex-notify '<json>'      Codex `notify` (JSON as last argument)
//   pulsedock-hook --self-test                 sends a test message, prints the outcome
//   pulsedock-hook --version
//
// Contract with the agents: never write to stdout while acting as a hook (stdout can become
// model context on some events), never block for long, and always exit 0. Failures are
// recorded locally in `run/helper-errors.log` without any payload content.

let startWall = Int64((Date().timeIntervalSince1970 * 1000).rounded())
let startMono = ProcessInspector.monotonicNanos

signal(SIGPIPE, SIG_IGN)
// Hard ceiling: whatever happens, the hook ends within two seconds with a success status.
signal(SIGALRM) { _ in _exit(0) }
alarm(2)

let arguments = CommandLine.arguments.dropFirst()
let mode = arguments.first ?? ""

func logFailure(_ message: String) {
    let url = BridgePaths.runDirectory.appendingPathComponent("helper-errors.log")
    guard (try? BridgePaths.ensurePrivateDirectory(BridgePaths.runDirectory)) != nil else { return }
    var info = stat()
    if stat(url.path, &info) == 0, info.st_size > 128 * 1024 { unlink(url.path) }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

func readStandardInput(limit: Int) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count > 0 {
            if data.count < limit { data.append(contentsOf: buffer[0..<min(count, limit - data.count)]) }
        } else if count == 0 {
            break
        } else if errno != EINTR {
            break
        }
    }
    return data
}

/// Forwards a Codex notification to the command that was configured before PulseDock was
/// installed, so existing integrations keep working. Detached; never waited on.
func forwardToPreviousNotifyCommand(_ argument: String) {
    let url = BridgePaths.supportDirectory.appendingPathComponent("codex-notify-chain.json")
    guard let data = try? Data(contentsOf: url),
          let command = try? JSONDecoder().decode([String].self, from: data),
          let executable = command.first, !executable.isEmpty else { return }
    var argv: [UnsafeMutablePointer<CChar>?] = (command + [argument]).map { strdup($0) }
    argv.append(nil)
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    let result = posix_spawnp(&pid, executable, nil, &attributes, argv, environ)
    posix_spawnattr_destroy(&attributes)
    if result != 0 { logFailure("notify-chain spawn failed errno=\(result)") }
}

switch mode {
case "--version":
    print(HookEnvelopeBuilder.helperVersion)

case "--self-test":
    let envelope = BridgeEnvelope(
        kind: .control,
        source: .pulsedock,
        event: "self-test",
        ts: startWall,
        boot: ProcessInspector.bootSessionID,
        mono: startMono,
        payload: .object(["session_id": .string("self-test")]),
        ctx: ProcessInspector.captureContext(),
        helper: HelperInfo(version: HookEnvelopeBuilder.helperVersion, pid: getpid())
    )
    let outcome = (try? envelope.encodedLine()).map { BridgeClient.send($0) } ?? .failed(EINVAL)
    switch outcome {
    case .delivered: print("delivered")
    case .unavailable: print("unavailable")
    case let .failed(code): print("failed \(code)")
    }

case "claude-code", "codex":
    let source: BridgeEnvelope.Source = mode == "codex" ? .codex : .claudeCode
    let hint = arguments.dropFirst().first
    let input = readStandardInput(limit: HookEnvelopeBuilder.maximumInputBytes)
    guard let envelope = HookEnvelopeBuilder.hookEnvelope(
        source: source,
        eventHint: hint,
        rawInput: input,
        context: ProcessInspector.captureContext(),
        options: SanitizerOptions.load(),
        startWall: startWall,
        startMono: startMono,
        bootID: ProcessInspector.bootSessionID,
        helperPID: getpid()
    ) else {
        logFailure("\(mode) \(hint ?? "?") unparseable input bytes=\(input.count)")
        break
    }
    switch HookEnvelopeBuilder.deliver(envelope) {
    case .delivered, .unavailable:
        break
    case let .failed(code):
        logFailure("\(mode) \(envelope.event) delivery failed errno=\(code)")
    }

case "codex-notify":
    guard let argument = arguments.last, arguments.count >= 2 else { break }
    if let envelope = HookEnvelopeBuilder.notifyEnvelope(
        argument: argument,
        context: ProcessInspector.captureContext(),
        startWall: startWall,
        startMono: startMono,
        bootID: ProcessInspector.bootSessionID,
        helperPID: getpid()
    ) {
        HookEnvelopeBuilder.deliver(envelope)
    } else {
        logFailure("codex-notify unparseable argument")
    }
    forwardToPreviousNotifyCommand(argument)

default:
    // Unknown invocation: drain stdin so the caller never blocks on a full pipe.
    _ = readStandardInput(limit: 1024)
}

exit(0)
