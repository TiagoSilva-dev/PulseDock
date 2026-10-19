import AppKit

/// `NSMenuItem` that runs a closure. The class is nonisolated because `NSMenuItem`'s
/// inherited initializers are; menus are only ever used on the main thread.
nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    @MainActor
    init(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [], state: NSControl.StateValue = .off, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        self.state = state
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() {
        let handler = self.handler
        MainActor.assumeIsolated { handler() }
    }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, symbol: String? = nil, state: NSControl.StateValue = .off, enabled: Bool = true, handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, symbol: symbol, state: state, handler: handler)
        item.isEnabled = enabled
        addItem(item)
        return item
    }

    func addSeparator() { addItem(.separator()) }

    func addSubmenu(_ title: String, symbol: String? = nil, build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let submenu = NSMenu(title: title)
        build(submenu)
        item.submenu = submenu
        addItem(item)
    }
}
