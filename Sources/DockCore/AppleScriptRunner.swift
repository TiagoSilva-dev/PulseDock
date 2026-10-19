import Foundation

/// Runs AppleScript through `osascript` off the main thread, so a slow target app or the
/// one-time Automation consent prompt never freezes the dock.
public nonisolated enum AppleScriptRunner {
    public struct Result: Sendable {
        public var output: String
        public var error: String?
        /// -1743: the user denied Automation for this target (System Settings › Privacy & Security).
        public var isPermissionDenied: Bool { error?.contains("-1743") == true }
    }

    public static func run(_ source: String, timeout: TimeInterval = 10, completion: (@MainActor @Sendable (String?) -> Void)? = nil) {
        execute(source, timeout: timeout) { result in completion?(result.error) }
    }

    public static func execute(_ source: String, timeout: TimeInterval = 10, completion: @escaping @MainActor @Sendable (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSynchronously(source, timeout: timeout)
            Task { @MainActor in completion(result) }
        }
    }

    public static func runSynchronously(_ source: String, timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return Result(output: "", error: error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            return Result(output: "", error: "timeout")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(output: text, error: process.terminationStatus == 0 ? nil : (errorText.isEmpty ? "exit \(process.terminationStatus)" : errorText))
    }

    /// Escapes a string for use inside an AppleScript string literal.
    public static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
