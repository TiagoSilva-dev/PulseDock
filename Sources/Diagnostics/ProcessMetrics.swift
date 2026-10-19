import Darwin
import Foundation

/// Lightweight self-measurement used by the Diagnostics pane and performance checks.
public enum ProcessMetrics {
    /// Physical footprint in bytes (the value Activity Monitor reports as "Memory").
    public static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Total CPU time (user + system) consumed by this process, in seconds.
    public static func cpuTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> TimeInterval {
            TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    public static func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

/// Samples CPU usage of this process between two calls.
public struct CPUUsageSampler: Sendable {
    private var lastCPU: TimeInterval
    private var lastWall: TimeInterval

    public init() {
        lastCPU = ProcessMetrics.cpuTime()
        lastWall = ProcessInfo.processInfo.systemUptime
    }

    /// Returns the average CPU usage (0...1 per core) since the previous sample.
    public mutating func sample() -> Double {
        let cpu = ProcessMetrics.cpuTime()
        let wall = ProcessInfo.processInfo.systemUptime
        defer {
            lastCPU = cpu
            lastWall = wall
        }
        let elapsed = wall - lastWall
        guard elapsed > 0 else { return 0 }
        return max(0, (cpu - lastCPU) / elapsed)
    }
}
