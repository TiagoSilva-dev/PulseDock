import Darwin
import Foundation
import Observation

/// Byte counters of the physical interfaces (Wi-Fi, Ethernet, cellular tethering).
public nonisolated struct InterfaceCounters: Hashable, Sendable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }

    /// Reads the link-layer counters of every "en*" interface that is up. Loopback, VPN
    /// tunnels (utun) and bridges are excluded so traffic is not counted twice.
    public static func read() -> InterfaceCounters {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return InterfaceCounters(received: 0, sent: 0) }
        defer { freeifaddrs(pointer) }
        var total = InterfaceCounters(received: 0, sent: 0)
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let data = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            total.received += UInt64(stats.ifi_ibytes)
            total.sent += UInt64(stats.ifi_obytes)
        }
        return total
    }

    /// Bytes per second between two samples. Counter resets (wrap or interface restart) give 0.
    public static func rate(from old: InterfaceCounters, to new: InterfaceCounters, seconds: TimeInterval) -> (down: Double, up: Double) {
        guard seconds > 0 else { return (0, 0) }
        let down = new.received >= old.received ? Double(new.received - old.received) / seconds : 0
        let up = new.sent >= old.sent ? Double(new.sent - old.sent) / seconds : 0
        return (down, up)
    }
}

/// Live download and upload speed. Samples every `interval` seconds only while visible.
@Observable
public final class NetworkRateProvider {
    public private(set) var downloadRate: Double = 0
    public private(set) var uploadRate: Double = 0
    public private(set) var downloadHistory: [Double] = []
    public private(set) var uploadHistory: [Double] = []
    public var interval: TimeInterval = 2 {
        didSet { if interval != oldValue { reschedule() } }
    }
    public var isVisible = false {
        didSet { if isVisible != oldValue { reschedule() } }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var last: (counters: InterfaceCounters, time: Date)?
    private static let historyLength = 40

    public init() {}

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        last = nil
        guard isVisible else { return }
        sample()
        let timer = Timer(timeInterval: max(1, interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        let counters = InterfaceCounters.read()
        let now = Date()
        if let last {
            let rate = InterfaceCounters.rate(from: last.counters, to: counters, seconds: now.timeIntervalSince(last.time))
            downloadRate = rate.down
            uploadRate = rate.up
            downloadHistory = Array((downloadHistory + [rate.down]).suffix(Self.historyLength))
            uploadHistory = Array((uploadHistory + [rate.up]).suffix(Self.historyLength))
        }
        last = (counters, now)
    }

    /// "1.2 MB/s", using the user's locale.
    public static func format(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = bytesPerSecond < 1_000_000 ? [.useKB] : [.useMB, .useGB]
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }
}
