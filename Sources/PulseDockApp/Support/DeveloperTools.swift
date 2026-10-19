import AgentBridge
import AgentCore
import AppKit
import Diagnostics
import DockRendering
import SwiftUI

/// Developer-only commands received through the local socket when PulseDock runs with
/// `--developer` (for example `pulsedockctl snapshot`). They render PulseDock's own views
/// to PNG files for visual review; they never capture other apps' windows.
enum DeveloperTools {
    @MainActor
    static func handle(_ event: String, payload: JSONValue, services: AppServices) {
        switch event {
        case "snapshot":
            let directory = payload["dir"]?.stringValue.map { URL(fileURLWithPath: $0) }
                ?? BridgePaths.supportDirectory.appendingPathComponent("snapshots")
            snapshot(services: services, to: directory, variant: payload["variant"]?.stringValue ?? "all")
        case "open":
            switch payload["what"]?.stringValue {
            case "card": if let frame = services.dockWindow.screenFrame(ofEntry: "agentPulse") { services.agentUI.showCard(anchor: frame) }
            case "missionControl": services.openMissionControl()
            case "settings": services.openSettings(pane: SettingsPane(rawValue: payload["pane"]?.stringValue ?? "") ?? .general)
            case "onboarding": services.windows.showOnboarding()
            default: break
            }
        case "demo":
            services.settings.update { $0.advanced.demoMode = payload["enabled"]?.boolValue ?? true }
        case "hover":
            // Simulates the pointer over the dock (x relative to the bar, 0…1) for snapshots.
            let fraction = payload["x"]?.stringValue.flatMap(Double.init) ?? 0.5
            let bar = services.dockModel.barRect
            services.dockModel.pointerMoved(to: CGPoint(x: bar.minX + bar.width * fraction, y: bar.midY))
        case "unhover":
            services.dockModel.pointerMoved(to: nil)
        case "appearance":
            // Light/dark review without changing the system-wide appearance.
            switch payload["mode"]?.stringValue {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
        case "sleep":
            // Runs the same handlers as NSWorkspace's sleep/wake notifications.
            services.systemWillSleep()
        case "wake":
            services.systemDidWake()
        default:
            DiagnosticsRecorder.shared.record(.warning, "developer", "unknown control \(event)")
        }
    }

    @MainActor
    static func snapshot(services: AppServices, to directory: URL, variant: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        // 1. The live dock window, exactly as rendered (materials need the window server and
        //    may appear flat in this offscreen rendering).
        if let image = render(services.dockWindow.host) {
            write(image, to: directory.appendingPathComponent("dock-live.png"))
            written.append("dock-live.png")
        }
        // 2. Open panels and windows.
        for window in NSApp.windows where window.isVisible && window !== services.dockWindow.panel {
            guard let view = window.contentView, let image = render(view) else { continue }
            let name = (window.title.isEmpty ? String(describing: type(of: window)) : window.title)
                .replacingOccurrences(of: " ", with: "-").lowercased()
            write(image, to: directory.appendingPathComponent("window-\(name).png"))
            written.append("window-\(name).png")
        }
        DiagnosticsRecorder.shared.record(.info, "developer", "snapshot: \(written.joined(separator: ", "))")
        PulseLog.app.info("Snapshots written: \(written.joined(separator: ", "), privacy: .public)")
    }

    @MainActor
    static func render(_ view: NSView) -> NSBitmapImageRep? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
