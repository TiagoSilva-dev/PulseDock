import AdapterSupport
import AgentBridge
import ClaudeCodeAdapter
import CodexAdapter
import Darwin
import Foundation

// pulsedockctl — developer tool. Sends fixtures through exactly the same sanitize → envelope
// → socket path used by the hook helper, so the pipeline can be exercised without an agent.
//
//   pulsedockctl paths
//   pulsedockctl ping
//   pulsedockctl send-hook <claude-code|codex> <file.json|-> [--event Name]
//   pulsedockctl notify '<codex notify json>'
//   pulsedockctl replay <file.jsonl> [--speed 2]
//   pulsedockctl claude-hooks status|install|uninstall
//   pulsedockctl claude-statusline status|preview|install|uninstall   (Claude Usage widget)
//   pulsedockctl uninstall-hooks            (Claude Code + Codex hooks + Codex notify)
//
// Replay files contain one object per line: {"delay": 0.5, "source": "claude-code", "payload": {…}}

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pulsedockctl: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func readInput(_ path: String) -> Data {
    if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

func describe(_ outcome: BridgeClient.Outcome) -> String {
    switch outcome {
    case .delivered: "delivered"
    case .unavailable: "PulseDock is not running (spooled)"
    case let .failed(code): "failed: \(String(cString: strerror(code)))"
    }
}

func sendHook(source: BridgeEnvelope.Source, data: Data, event: String?) -> BridgeClient.Outcome {
    let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
    guard let envelope = HookEnvelopeBuilder.hookEnvelope(
        source: source,
        eventHint: event,
        rawInput: data,
        context: ProcessInspector.captureContext(),
        options: SanitizerOptions.load(),
        startWall: now,
        startMono: ProcessInspector.monotonicNanos,
        bootID: ProcessInspector.bootSessionID,
        helperPID: getpid()
    ) else { fail("payload needs hook_event_name (or --event) and session_id") }
    return HookEnvelopeBuilder.deliver(envelope)
}

func parseSource(_ value: String) -> BridgeEnvelope.Source {
    switch value {
    case "claude-code", "claude_code", "claude": .claudeCode
    case "codex": .codex
    default: fail("unknown source \(value)")
    }
}

switch arguments.first {
case "paths":
    print("support: \(BridgePaths.supportDirectory.path)")
    print("socket:  \(BridgePaths.socketPath)")
    print("spool:   \(BridgePaths.spool.path)")
    print("helper:  \(BridgePaths.installedHelper.path)")

case "ping":
    let envelope = BridgeEnvelope(
        kind: .control, source: .pulsedock, event: "ping",
        ts: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
        boot: ProcessInspector.bootSessionID, mono: ProcessInspector.monotonicNanos,
        payload: .object(["session_id": .string("ping")]), ctx: nil,
        helper: HelperInfo(version: HookEnvelopeBuilder.helperVersion, pid: getpid())
    )
    guard let line = try? envelope.encodedLine() else { fail("encoding") }
    print(describe(BridgeClient.send(line)))

case "send-hook":
    guard arguments.count >= 3 else { fail("usage: send-hook <claude-code|codex> <file.json|-> [--event Name]") }
    print(describe(sendHook(source: parseSource(arguments[1]), data: readInput(arguments[2]), event: option("--event"))))

case "notify":
    guard arguments.count >= 2 else { fail("usage: notify '<json>'") }
    let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
    guard let envelope = HookEnvelopeBuilder.notifyEnvelope(
        argument: arguments[1], context: ProcessInspector.captureContext(), startWall: now,
        startMono: ProcessInspector.monotonicNanos, bootID: ProcessInspector.bootSessionID, helperPID: getpid()
    ) else { fail("invalid notify payload") }
    print(describe(HookEnvelopeBuilder.deliver(envelope)))

case "replay":
    guard arguments.count >= 2 else { fail("usage: replay <file.jsonl> [--speed 2]") }
    let speed = max(0.01, Double(option("--speed") ?? "1") ?? 1)
    let data = readInput(arguments[1])
    var sent = 0
    for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let payload = object["payload"] else { continue }
        if let delay = object["delay"] as? Double, delay > 0 {
            usleep(useconds_t(min(delay / speed, 30) * 1_000_000))
        }
        let source = parseSource(object["source"] as? String ?? "claude-code")
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { continue }
        let outcome = sendHook(source: source, data: payloadData, event: nil)
        sent += 1
        let name = (payload as? [String: Any])?["hook_event_name"] as? String ?? "?"
        print("[\(sent)] \(name): \(describe(outcome))")
    }

case "claude-statusline":
    // Same installer as Settings › AI Agents › Claude usage: preview, backup, validation.
    let installation = ClaudeCodeDetector.detect()
    let installer = ClaudeStatusLineInstaller(settingsURL: installation.settingsURL)
    do {
        switch arguments.dropFirst().first ?? "status" {
        case "preview":
            let plan = try installer.planInstall()
            print(plan.change.previewLines.filter { $0.hasPrefix("+") || $0.hasPrefix("-") }.joined(separator: "\n"))
        case "install":
            let plan = try installer.planInstall()
            let backup = try installer.apply(plan)
            print("status line installed\(plan.chained == nil ? "" : " (your own status line is chained)"); backup: \(backup?.path ?? "none")")
        case "uninstall":
            let plan = try installer.planUninstall()
            let backup = try installer.apply(plan)
            print("status line removed\(plan.change.preservedForeignHandlers > 0 ? " (your own status line restored)" : ""); backup: \(backup?.path ?? "none")")
        default:
            print(installer.status())
        }
    } catch { fail("claude-statusline failed: \(error)") }

case "claude-hooks":
    // pulsedockctl claude-hooks status|install|uninstall   (same installer as the app: backup + validation)
    let installation = ClaudeCodeDetector.detect()
    let installer = ClaudeCodeHookInstaller(settingsURL: installation.settingsURL)
    switch arguments.dropFirst().first ?? "status" {
    case "install":
        do {
            let plan = try installer.planInstall(version: installation.version)
            let backup = try installer.apply(plan)
            print("installed \(plan.addedEvents.count) events; preserved \(plan.preservedForeignHandlers) foreign handlers; backup: \(backup?.path ?? "none (new file)")")
        } catch { fail("install failed: \(error)") }
    case "uninstall":
        do {
            let plan = try installer.planUninstall()
            let backup = try installer.apply(plan)
            print("removed \(plan.removedHandlers) handlers; backup: \(backup?.path ?? "none")")
        } catch { fail("uninstall failed: \(error)") }
    default:
        print("claude \(installation.version ?? "?") at \(installation.executablePath ?? "not found"): \(installer.status(version: installation.version))")
    }

case "uninstall-hooks":
    // Removes every PulseDock entry from Claude Code and Codex (hooks and notify), through the
    // same installers the app uses: backups first, foreign handlers untouched.
    var failures = 0
    let claude = ClaudeCodeHookInstaller(settingsURL: ClaudeCodeDetector.detect().settingsURL)
    do {
        let plan = try claude.planUninstall()
        if plan.removedHandlers > 0 {
            let backup = try claude.apply(plan)
            print("Claude Code: removed \(plan.removedHandlers) handlers (backup: \(backup?.path ?? "none"))")
        } else { print("Claude Code: nothing to remove") }
    } catch { failures += 1; print("Claude Code: \(error)") }
    let codexHome = CodexDetector.homeDirectory
    let hooks = CodexHookInstaller(hooksURL: codexHome.appendingPathComponent("hooks.json"))
    do {
        let plan = try hooks.planUninstall()
        if plan.removedHandlers > 0 {
            let backup = try hooks.apply(plan)
            print("Codex hooks: removed \(plan.removedHandlers) handlers (backup: \(backup?.path ?? "none"))")
        } else { print("Codex hooks: nothing to remove") }
    } catch { failures += 1; print("Codex hooks: \(error)") }
    let notify = CodexNotifyInstaller(configURL: codexHome.appendingPathComponent("config.toml"))
    if notify.isInstalled() {
        do {
            try notify.applyUninstall(try notify.planUninstall())
            print("Codex notify: restored")
        } catch { failures += 1; print("Codex notify: \(error)") }
    } else { print("Codex notify: nothing to remove") }
    exit(failures == 0 ? 0 : 1)

case "control":
    // Developer commands (PulseDock must run with --developer):
    //   pulsedockctl control snapshot dir=/tmp/shots     pulsedockctl control demo enabled=true
    //   pulsedockctl control open what=card              pulsedockctl control hover x=0.3
    guard arguments.count >= 2 else { fail("usage: control <event> [key=value …]") }
    var payload: [String: JSONValue] = ["session_id": .string("control")]
    for pair in arguments.dropFirst(2) {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        payload[parts[0]] = parts[1] == "true" ? .bool(true) : (parts[1] == "false" ? .bool(false) : .string(parts[1]))
    }
    let envelope = BridgeEnvelope(
        kind: .control, source: .pulsedock, event: arguments[1],
        ts: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
        boot: ProcessInspector.bootSessionID, mono: ProcessInspector.monotonicNanos,
        payload: .object(payload), ctx: nil,
        helper: HelperInfo(version: HookEnvelopeBuilder.helperVersion, pid: getpid())
    )
    guard let line = try? envelope.encodedLine() else { fail("encoding") }
    print(describe(BridgeClient.send(line)))

default:
    fail("usage: pulsedockctl <paths|ping|send-hook|notify|replay|claude-hooks|uninstall-hooks|control> …")
}
