import Darwin
import Foundation

/// Reads process metadata with `libproc` (same-user processes, no special permission).
public enum ProcessInspector {
    public struct Info: Sendable, Hashable {
        public var pid: Int32
        public var ppid: Int32
        public var start: Int64
        public var name: String
        public var ttyDevice: UInt32?
    }

    public static func info(pid: Int32) -> Info? {
        guard pid > 0 else { return nil }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size)
        // libproc refuses processes owned by other users (for example `login`, which sits
        // between Terminal and the shell); sysctl exposes the same basics for any process.
        guard result == size else { return sysctlInfo(pid: pid) }
        let name = withUnsafeBytes(of: bsd.pbi_name) { buffer -> String in
            let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            return text
        }
        let comm = withUnsafeBytes(of: bsd.pbi_comm) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        let tty: UInt32? = (bsd.e_tdev == UInt32.max || bsd.e_tdev == 0) ? nil : bsd.e_tdev
        return Info(
            pid: Int32(bsd.pbi_pid),
            ppid: Int32(bsd.pbi_ppid),
            start: Int64(bsd.pbi_start_tvsec),
            name: name.isEmpty ? comm : name,
            ttyDevice: tty
        )
    }

    private static func sysctlInfo(pid: Int32) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &process, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size,
              process.kp_proc.p_pid == pid else { return nil }
        let name = withUnsafeBytes(of: process.kp_proc.p_comm) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        let device = UInt32(bitPattern: process.kp_eproc.e_tdev)
        return Info(
            pid: pid,
            ppid: process.kp_eproc.e_ppid,
            start: Int64(process.kp_proc.p_starttime.tv_sec),
            name: name,
            ttyDevice: (device == UInt32.max || device == 0) ? nil : device
        )
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(nulTerminated: buffer)
    }

    public static func ttyName(device: UInt32) -> String? {
        guard let name = devname(dev_t(bitPattern: device), mode_t(S_IFCHR)) else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text == "??" ? nil : text
    }

    /// True if `pid` exists and, when `start` is given, is still the same process.
    public static func isAlive(pid: Int32, start: Int64?) -> Bool {
        guard let info = info(pid: pid) else { return false }
        if let start, start > 0 { return info.start == start }
        return true
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "login", "tcsh", "csh", "ksh", "nu"]

    /// Captures the ancestry of the current process, parent first.
    public static func captureContext(maxDepth: Int = 10, environment: [String: String] = ProcessInfo.processInfo.environment) -> ProcessContext {
        var chain: [ProcessEntry] = []
        var tty: String?
        var pid = getppid()
        for _ in 0..<maxDepth {
            guard pid > 1, let info = info(pid: pid) else { break }
            chain.append(ProcessEntry(pid: info.pid, ppid: info.ppid, start: info.start, name: info.name, path: executablePath(pid: info.pid)))
            if tty == nil, let device = info.ttyDevice { tty = ttyName(device: device) }
            pid = info.ppid
        }
        var env: [String: String] = [:]
        for key in ProcessContext.environmentWhitelist {
            if let value = environment[key], !value.isEmpty {
                env[key] = String(value.prefix(256))
            }
        }
        if environment["TMUX"] != nil { env["TMUX"] = "1" }
        return ProcessContext(chain: chain, tty: tty, env: env)
    }

    /// The agent process: the nearest ancestor that is not a shell or wrapper.
    public static func agentProcess(in context: ProcessContext) -> ProcessEntry? {
        context.chain.first { !shells.contains($0.name.lowercased()) && !$0.name.hasPrefix("-") }
    }

    /// Nearest ancestor running inside an application bundle (the terminal or editor
    /// hosting the agent), with that bundle's path.
    public static func hostApplication(in context: ProcessContext) -> (entry: ProcessEntry, bundlePath: String)? {
        for entry in context.chain {
            guard let path = entry.path, let range = path.range(of: ".app/") else { continue }
            let bundlePath = String(path[..<range.lowerBound]) + ".app"
            return (entry, bundlePath)
        }
        return nil
    }

    public static func bundleIdentifier(atPath path: String) -> String? {
        let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return object["CFBundleIdentifier"] as? String
    }

    /// Boot session identifier (monotonic clocks are only comparable within one boot).
    public static var bootSessionID: String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(nulTerminated: buffer)
    }

    public static var monotonicNanos: UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }
}

extension String {
    /// Decodes a NUL-terminated C buffer as UTF-8.
    init(nulTerminated buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self = String(decoding: bytes, as: UTF8.self)
    }
}
