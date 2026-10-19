import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's `RegisterEventHotKey`, which needs no
/// Accessibility permission (unlike global key monitors).
///
/// - ⌃⌥⌘P toggles Privacy Mode (for presentations and screen sharing).
/// - ⌃⌥⌘W switches to the next PulseDock workspace.
final class HotKeys {
    static let shared = HotKeys()

    enum Action: UInt32, CaseIterable {
        case togglePrivacy = 1
        case nextWorkspace = 2

        var keyCode: UInt32 {
            switch self {
            case .togglePrivacy: UInt32(kVK_ANSI_P)
            case .nextWorkspace: UInt32(kVK_ANSI_W)
            }
        }

        var modifiers: UInt32 { UInt32(cmdKey | optionKey | controlKey) }

        var displayShortcut: String {
            switch self {
            case .togglePrivacy: "⌃⌥⌘P"
            case .nextWorkspace: "⌃⌥⌘W"
            }
        }
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x5044_6F6B // "PDok"

    func register(_ action: Action, handler: @escaping () -> Void) {
        installEventHandlerIfNeeded()
        handlers[action.rawValue] = handler
        if let existing = references[action.rawValue] {
            UnregisterEventHotKey(existing)
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: action.rawValue)
        let status = RegisterEventHotKey(action.keyCode, action.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            references[action.rawValue] = reference
        }
    }

    func unregisterAll() {
        references.values.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ identifier: UInt32) {
        handlers[identifier]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let id = identifier.id
            MainActor.assumeIsolated { HotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
