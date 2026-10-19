import AppKit
import Diagnostics
import DockCore
import DockRendering
import Persistence
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: [String]
    private(set) var services: AppServices?

    init(arguments: [String]) {
        self.arguments = arguments
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStarted = Date()
        // A dock must stay alive without visible document windows.
        ProcessInfo.processInfo.disableAutomaticTermination("PulseDock is a persistent dock")
        ProcessInfo.processInfo.disableSuddenTermination()
        let persistence: PersistenceController?
        do {
            persistence = try PersistenceController()
        } catch {
            PulseLog.persistence.fault("Database unavailable: \(String(describing: error), privacy: .public)")
            DiagnosticsRecorder.shared.record(.error, "persistence", "database unavailable: \(error)")
            persistence = nil
        }
        let services = AppServices(persistence: persistence, arguments: arguments)
        self.services = services
        services.start()
        let elapsed = Date().timeIntervalSince(launchStarted)
        PulseLog.performance.info("Launch completed in \(Int(elapsed * 1000), privacy: .public) ms")
        DiagnosticsRecorder.shared.record(.info, "app", "launched in \(Int(elapsed * 1000)) ms")
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services?.openSettings()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
