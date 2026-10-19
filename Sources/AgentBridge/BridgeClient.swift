import Darwin
import Foundation

/// Fire-and-forget delivery used by the hook helper. Every call is bounded by `timeout` so
/// the agent is never slowed down noticeably, whether or not PulseDock is running.
public enum BridgeClient {
    public enum Outcome: Equatable, Sendable {
        case delivered
        /// Nobody is listening (PulseDock not running).
        case unavailable
        case failed(Int32)
    }

    public static func send(_ data: Data, socketPath: String = BridgePaths.socketPath, timeout: TimeInterval = 0.3) -> Outcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed(errno) }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        guard var address = makeAddress(socketPath) else { return .failed(ENAMETOOLONG) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        if connected != 0 {
            switch errno {
            case ENOENT, ECONNREFUSED:
                return .unavailable
            case EINPROGRESS, EAGAIN:
                guard waitWritable(fd, until: deadline) else { return .failed(ETIMEDOUT) }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error == ECONNREFUSED || error == ENOENT { return .unavailable }
                if error != 0 { return .failed(error) }
            default:
                return .failed(errno)
            }
        }

        var offset = 0
        let total = data.count
        while offset < total {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), total - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                guard waitWritable(fd, until: deadline) else { return .failed(ETIMEDOUT) }
            } else {
                return .failed(errno)
            }
        }
        shutdown(fd, SHUT_WR)
        return .delivered
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func waitWritable(_ fd: Int32, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
            if result > 0 { return true }
            if result < 0, errno == EINTR { continue }
            return false
        }
    }
}

/// Append-only spool used when PulseDock is not running, so a restart does not lose the
/// events of sessions that kept going. Bounded in size; drained by the app on launch.
public enum BridgeSpool {
    public static let maximumBytes = 4 * 1024 * 1024

    @discardableResult
    public static func append(_ line: Data, to url: URL = BridgePaths.spool) -> Bool {
        do {
            try BridgePaths.ensurePrivateDirectory(url.deletingLastPathComponent())
        } catch {
            return false
        }
        var info = stat()
        if stat(url.path, &info) == 0, Int(info.st_size) + line.count > maximumBytes {
            return false
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = line.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(fd, base, buffer.count)
        }
        return written == line.count
    }

    /// Atomically takes the current spool (rename) and returns its lines.
    public static func drain(from url: URL = BridgePaths.spool) -> [Data] {
        let claimed = url.deletingLastPathComponent().appendingPathComponent("spool.draining-\(getpid()).jsonl")
        guard rename(url.path, claimed.path) == 0 else { return [] }
        defer { unlink(claimed.path) }
        guard let data = try? Data(contentsOf: claimed), data.count <= maximumBytes * 2 else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }
}
