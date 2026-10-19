import Foundation

/// Edits the `hooks` section shared by Claude Code `settings.json` and Codex `hooks.json`:
///
///     { "hooks": { "<Event>": [ { "matcher": "…", "hooks": [ { "type": "command", … } ] } ] } }
///
/// PulseDock handlers are recognised by `isOwnedHandler`. Installing first removes any
/// existing PulseDock handler (upgrade), then appends one matcher group per event. Every
/// other handler, group, event and top-level key is preserved in its original order.
public struct HooksSectionEditor {
    public struct Handler: Sendable, Equatable {
        public var event: String
        public var matcher: String?
        public var command: String
        public var timeout: Int?

        public init(event: String, matcher: String?, command: String, timeout: Int?) {
            self.event = event
            self.matcher = matcher
            self.command = command
            self.timeout = timeout
        }

        var json: OrderedJSON {
            var handler: [(String, OrderedJSON)] = [("type", .string("command")), ("command", .string(command))]
            if let timeout { handler.append(("timeout", .number(String(timeout)))) }
            var group: [(String, OrderedJSON)] = []
            if let matcher { group.append(("matcher", .string(matcher))) }
            group.append(("hooks", .array([.object(handler)])))
            return .object(group)
        }
    }

    public let isOwnedHandler: @Sendable (OrderedJSON) -> Bool

    public init(isOwnedHandler: @escaping @Sendable (OrderedJSON) -> Bool) {
        self.isOwnedHandler = isOwnedHandler
    }

    public struct Result {
        public var root: OrderedJSON
        public var removedHandlers: Int
        public var foreignHandlers: Int
    }

    /// Removes PulseDock handlers everywhere, then adds `handlers`.
    public func install(_ handlers: [Handler], into root: OrderedJSON) throws -> Result {
        let cleaned = try remove(from: root)
        guard case var .object(hooks) = cleaned.root["hooks"] ?? .object([]) else { throw ConfigEditError.unexpectedHooksShape }
        for handler in handlers {
            if let index = hooks.firstIndex(where: { $0.0 == handler.event }) {
                guard case var .array(groups) = hooks[index].1 else { throw ConfigEditError.unexpectedHooksShape }
                groups.append(handler.json)
                hooks[index].1 = .array(groups)
            } else {
                hooks.append((handler.event, .array([handler.json])))
            }
        }
        return Result(root: cleaned.root.setting("hooks", to: .object(hooks)), removedHandlers: cleaned.removedHandlers, foreignHandlers: cleaned.foreignHandlers)
    }

    /// Removes only PulseDock handlers. Groups and events left empty by that removal are
    /// dropped; the `hooks` key is dropped too when `dropEmptyHooksKey` and nothing remains.
    public func remove(from root: OrderedJSON, dropEmptyHooksKey: Bool = false) throws -> Result {
        guard root.objectPairs != nil else { throw ConfigEditError.notAnObject }
        guard let hooksValue = root["hooks"] else {
            return Result(root: root, removedHandlers: 0, foreignHandlers: 0)
        }
        guard case let .object(events) = hooksValue else { throw ConfigEditError.unexpectedHooksShape }
        var removed = 0
        var foreign = 0
        var keptEvents: [(String, OrderedJSON)] = []
        for (event, value) in events {
            guard case let .array(groups) = value else {
                keptEvents.append((event, value))
                continue
            }
            var keptGroups: [OrderedJSON] = []
            for group in groups {
                guard case let .array(handlers) = group["hooks"] ?? .null else {
                    keptGroups.append(group)
                    continue
                }
                let kept = handlers.filter { !isOwnedHandler($0) }
                removed += handlers.count - kept.count
                foreign += kept.count
                if kept.isEmpty, !handlers.isEmpty { continue }
                keptGroups.append(kept.count == handlers.count ? group : group.setting("hooks", to: .array(kept)))
            }
            if keptGroups.isEmpty, !groups.isEmpty { continue }
            keptEvents.append((event, .array(keptGroups)))
        }
        if keptEvents.isEmpty, dropEmptyHooksKey {
            return Result(root: root.removing("hooks"), removedHandlers: removed, foreignHandlers: foreign)
        }
        return Result(root: root.setting("hooks", to: .object(keptEvents)), removedHandlers: removed, foreignHandlers: foreign)
    }

    /// Events that currently contain at least one PulseDock handler.
    public func installedEvents(in root: OrderedJSON) -> [String] {
        guard case let .object(events) = root["hooks"] ?? .null else { return [] }
        return events.compactMap { event, value in
            guard case let .array(groups) = value else { return nil }
            let owned = groups.contains { group in
                (group["hooks"]?.arrayValue ?? []).contains(where: isOwnedHandler)
            }
            return owned ? event : nil
        }
    }
}
