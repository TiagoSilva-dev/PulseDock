import Darwin
import Diagnostics
import Foundation
import IOKit.ps
import Observation

/// CPU, memory and battery for the System Health widget.
///
/// CPU and memory are sampled with cheap Mach calls at a configurable interval, only while
/// the widget is visible. Battery uses IOKit power-source notifications (no polling).
@Observable
public final class SystemHealthProvider {
    public struct Battery: Equatable, Sendable {
        public var level: Double
        public var isCharging: Bool
        public var isPluggedIn: Bool
        /// Minutes to empty (or to full when charging), when macOS has an estimate.
        public var minutesRemaining: Int?
    }

    public private(set) var cpuUsage: Double = 0
    public private(set) var memoryUsed: UInt64 = 0
    public let memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    public private(set) var battery: Battery?
    public private(set) var cpuHistory: [Double] = []

    public var interval: TimeInterval = 5 {
        didSet { if interval != oldValue { reschedule() } }
    }
    public var isVisible = true {
        didSet { if isVisible != oldValue { reschedule() } }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    @ObservationIgnored private var powerSource: CFRunLoopSource?

    public init() {
        sample()
        reschedule()
        refreshBattery()
        installPowerNotification()
    }

    public var memoryFraction: Double {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isVisible else { return }
        let timer = Timer(timeInterval: max(1, interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = max(0.5, interval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    public func sample() {
        cpuUsage = readCPU() ?? cpuUsage
        cpuHistory.append(cpuUsage)
        if cpuHistory.count > 24 { cpuHistory.removeFirst(cpuHistory.count - 24) }
        memoryUsed = readMemoryUsed() ?? memoryUsed
    }

    private func readCPU() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = (
            user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3)
        )
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return nil }
        let user = ticks.user &- previous.user
        let system = ticks.system &- previous.system
        let idle = ticks.idle &- previous.idle
        let nice = ticks.nice &- previous.nice
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return Double(user + system + nice) / Double(total)
    }

    /// "Memory used" as Activity Monitor computes it: app memory + wired + compressed.
    private func readMemoryUsed() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let appMemory = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let used = appMemory + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return used * UInt64(pageSize)
    }

    // MARK: Battery

    private func installPowerNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let provider = Unmanaged<SystemHealthProvider>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { provider.refreshBattery() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    public func refreshBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            battery = nil
            return
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let plugged = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutes = charging ? description[kIOPSTimeToFullChargeKey] as? Int : description[kIOPSTimeToEmptyKey] as? Int
            battery = Battery(level: Double(current) / Double(maximum), isCharging: charging, isPluggedIn: plugged,
                              minutesRemaining: (minutes ?? -1) >= 0 ? minutes : nil)
            return
        }
        battery = nil
    }
}
