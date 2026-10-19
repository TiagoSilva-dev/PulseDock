import Foundation

/// Builds bridge envelopes from raw hook input. Shared by the hook helper and by
/// `pulsedockctl` so fixtures travel exactly the same path as real hooks.
public enum HookEnvelopeBuilder {
    public static let helperVersion = "0.1.0"

    /// Maximum hook input accepted on stdin. Larger payloads (huge tool responses) are
    /// truncated and, if unparseable, reduced to the event name taken from argv.
    public static let maximumInputBytes = 16 * 1024 * 1024

    public static func hookEnvelope(
        source: BridgeEnvelope.Source,
        eventHint: String?,
        rawInput: Data,
        context: ProcessContext?,
        options: SanitizerOptions,
        startWall: Int64,
        startMono: UInt64?,
        bootID: String?,
        helperPID: Int32
    ) -> BridgeEnvelope? {
        let object = (try? JSONSerialization.jsonObject(with: rawInput)) as? [String: Any] ?? [:]
        let event = (object["hook_event_name"] as? String) ?? eventHint
        guard let event, !event.isEmpty, event.count <= 64 else { return nil }
        // Without a session id an event cannot be attributed; drop it.
        guard let sessionID = object["session_id"] as? String, !sessionID.isEmpty, sessionID.count <= 256 else { return nil }
        let payload = HookSanitizer.sanitize(event: event, input: object, options: options)
        return BridgeEnvelope(
            kind: .hook,
            source: source,
            event: event,
            ts: startWall,
            boot: bootID,
            mono: startMono,
            payload: payload,
            ctx: context,
            helper: HelperInfo(version: helperVersion, pid: helperPID)
        )
    }

    /// Codex `notify`: the JSON payload is the last command-line argument.
    public static func notifyEnvelope(
        argument: String,
        context: ProcessContext?,
        startWall: Int64,
        startMono: UInt64?,
        bootID: String?,
        helperPID: Int32
    ) -> BridgeEnvelope? {
        guard let data = argument.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String, !type.isEmpty,
              object["thread-id"] is String else { return nil }
        return BridgeEnvelope(
            kind: .notify,
            source: .codex,
            event: String(type.prefix(64)),
            ts: startWall,
            boot: bootID,
            mono: startMono,
            payload: HookSanitizer.sanitizeNotify(input: object),
            ctx: context,
            helper: HelperInfo(version: helperVersion, pid: helperPID)
        )
    }

    /// Delivers an envelope or spools it when PulseDock is not listening.
    @discardableResult
    public static func deliver(_ envelope: BridgeEnvelope, socketPath: String = BridgePaths.socketPath, spool: URL = BridgePaths.spool) -> BridgeClient.Outcome {
        guard let line = try? envelope.encodedLine() else { return .failed(EINVAL) }
        let outcome = BridgeClient.send(line, socketPath: socketPath)
        if outcome != .delivered {
            BridgeSpool.append(line, to: spool)
        }
        return outcome
    }
}
