import AppKit
import Diagnostics

/// Entry point used by the `PulseDock` executable.
public enum PulseDockApplication {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate(arguments: CommandLine.arguments)
        app.delegate = delegate
        // An agent app: no Dock icon, no app switcher entry. Windows such as Settings switch
        // to `.regular` temporarily while they are open.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
