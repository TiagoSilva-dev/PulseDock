import Foundation
import Observation

/// Lists and runs the user's shortcuts through `/usr/bin/shortcuts`, the command-line tool
/// Apple ships with the Shortcuts app.
@Observable
public final class ShortcutsRunner {
    public private(set) var shortcuts: [String] = []
    public private(set) var running: Set<String> = []
    public private(set) var lastResult: (name: String, succeeded: Bool)?
    public nonisolated static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    public init() {}

    public var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: Self.tool.path) }

    public func reload() {
        guard isAvailable else { return }
        Task { @MainActor in
            let output = await Self.execute(["list"])
            shortcuts = output.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    public func run(_ name: String) {
        guard isAvailable, !running.contains(name) else { return }
        running.insert(name)
        Task { @MainActor in
            let result = await Self.execute(["run", name])
            running.remove(name)
            lastResult = (name, result.status == 0)
        }
    }

    /// Runs the tool off the main thread with a 60-second ceiling.
    nonisolated static func execute(_ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, ""))
                    return
                }
                let deadline = DispatchTime.now() + 60
                DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
