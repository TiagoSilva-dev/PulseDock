import Foundation
import os

/// Central OSLog categories. Messages logged here never contain prompts, file contents
/// or command output: callers pass already-sanitized values and mark dynamic values
/// `privacy: .private` unless they are identifiers we generated ourselves.
public enum PulseLog {
    public static let subsystem: String = Bundle.main.bundleIdentifier ?? "app.pulsedock.PulseDock"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let dock = Logger(subsystem: subsystem, category: "dock")
    public static let agents = Logger(subsystem: subsystem, category: "agents")
    public static let bridge = Logger(subsystem: subsystem, category: "bridge")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let widgets = Logger(subsystem: subsystem, category: "widgets")
    public static let integrations = Logger(subsystem: subsystem, category: "integrations")
    public static let performance = Logger(subsystem: subsystem, category: "performance")
}
