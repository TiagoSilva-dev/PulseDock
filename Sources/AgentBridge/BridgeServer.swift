import Darwin
import Foundation

/// Local Unix-domain socket server receiving envelopes from the hook helper.
///
/// Security model:
/// - The socket lives in a 0700 directory owned by the user and is itself 0600.
/// - Every connection is checked with `getpeereid`; other users are rejected.
/// - Messages are newline-delimited JSON, capped at `maxMessageBytes`, validated before use.
/// - Connections that do not finish within `connectionTimeout` are closed.
/// - There is no TCP or HTTP endpoint.
public final class BridgeServer: @unchecked Sendable {
    public struct Statistics: Sendable, Equatable {
        public var accepted = 0
        public var rejectedPeers = 0
        public var invalidMessages = 0
        public var oversized = 0
        public var lastMessageAt: Date?
    }

    public let socketPath: String
    public let maxMessageBytes: Int
    public let connectionTimeout: TimeInterval
    private let queue = DispatchQueue(label: "app.pulsedock.bridge", qos: .userInitiated)
    private let handler: @Sendable (BridgeEnvelope) -> Void
    private var listenSource: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var connections: [Int32: Connection] = [:]
    private var stats = Statistics()
    private let maxConnections = 64

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        let opened = Date()
        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    public init(
        socketPath: String = BridgePaths.socketPath,
        maxMessageBytes: Int = 512 * 1024,
        connectionTimeout: TimeInterval = 2,
        handler: @escaping @Sendable (BridgeEnvelope) -> Void
    ) {
        self.socketPath = socketPath
        self.maxMessageBytes = maxMessageBytes
        self.connectionTimeout = connectionTimeout
        self.handler = handler
    }

    public var statistics: Statistics { queue.sync { stats } }
    public var isListening: Bool { queue.sync { listenFD >= 0 } }

    public func start() throws {
        try queue.sync {
            guard listenFD < 0 else { return }
            let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            try BridgePaths.ensurePrivateDirectory(directory)

            // A socket file may be left over from a crash; only remove it if nobody answers.
            if FileManager.default.fileExists(atPath: socketPath) {
                if BridgeClient.send(Data(), socketPath: socketPath, timeout: 0.1) == .delivered {
                    throw BridgeError.alreadyRunning
                }
                unlink(socketPath)
            }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BridgeError.socket("socket", errno) }
            guard var address = BridgeClient.makeAddress(socketPath) else {
                close(fd)
                throw BridgeError.socket("path", ENAMETOOLONG)
            }
            let previousMask = umask(0o077)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            umask(previousMask)
            guard bound == 0 else {
                let code = errno
                close(fd)
                throw BridgeError.socket("bind", code)
            }
            chmod(socketPath, 0o600)
            guard listen(fd, 64) == 0 else {
                let code = errno
                close(fd)
                unlink(socketPath)
                throw BridgeError.socket("listen", code)
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            listenFD = fd

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { close(fd) }
            source.resume()
            listenSource = source
        }
    }

    public func stop() {
        queue.sync {
            for connection in connections.values { connection.source.cancel() }
            connections.removeAll()
            listenSource?.cancel()
            listenSource = nil
            if listenFD >= 0 {
                listenFD = -1
                unlink(socketPath)
            }
        }
    }

    deinit {
        listenSource?.cancel()
    }

    // MARK: Accept and read (on `queue`)

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                stats.rejectedPeers += 1
                close(client)
                continue
            }
            guard connections.count < maxConnections else {
                close(client)
                continue
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            let connection = Connection(fd: client, source: source)
            connections[client] = connection
            source.setEventHandler { [weak self] in self?.read(client) }
            source.setCancelHandler { close(client) }
            source.resume()
            let identity = ObjectIdentifier(connection)
            queue.asyncAfter(deadline: .now() + connectionTimeout) { [weak self] in
                guard let self, let open = self.connections[client], ObjectIdentifier(open) == identity else { return }
                self.finish(client, process: false)
            }
        }
    }

    private func read(_ fd: Int32) {
        guard let connection = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                connection.buffer.append(contentsOf: chunk[0..<count])
                if connection.buffer.count > maxMessageBytes {
                    stats.oversized += 1
                    finish(fd, process: false)
                    return
                }
            } else if count == 0 {
                finish(fd, process: true)
                return
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                finish(fd, process: false)
                return
            }
        }
    }

    private func finish(_ fd: Int32, process: Bool) {
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.source.cancel()
        guard process else { return }
        for line in connection.buffer.split(separator: 0x0A, omittingEmptySubsequences: true) {
            deliver(Data(line))
        }
    }

    /// Decodes and validates one line, then calls the handler. Runs on `queue`.
    private func deliver(_ line: Data) {
        guard line.count <= maxMessageBytes else {
            stats.oversized += 1
            return
        }
        do {
            let envelope = try BridgeEnvelope.decode(line: line)
            try envelope.validate()
            stats.accepted += 1
            stats.lastMessageAt = Date()
            handler(envelope)
        } catch {
            stats.invalidMessages += 1
        }
    }

    /// Replays spooled lines through the same validation path, on the server queue.
    public func replay(_ lines: [Data]) {
        queue.async { [weak self] in
            for line in lines { self?.deliver(line) }
        }
    }
}
