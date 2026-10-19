import Darwin
import Foundation

/// Filesystem locations shared by the app and the hook helper.
///
/// Everything lives in `~/Library/Application Support/PulseDock`. The `run` directory holding
/// the socket and the spool is created with mode 0700 and verified (owner, mode, not a
/// symlink) before use. `PULSEDOCK_HOME` overrides the root for tests.
public enum BridgePaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PULSEDOCK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PulseDock", isDirectory: true)
    }

    public static var runDirectory: URL { supportDirectory.appendingPathComponent("run", isDirectory: true) }
    public static var binDirectory: URL { supportDirectory.appendingPathComponent("bin", isDirectory: true) }
    public static var backupsDirectory: URL { supportDirectory.appendingPathComponent("backups", isDirectory: true) }

    /// Stable location of the hook helper referenced from agent configuration files, so the
    /// hooks keep working if the app bundle moves.
    public static var installedHelper: URL { binDirectory.appendingPathComponent("pulsedock-hook") }

    /// Privacy options the helper reads before sanitizing (written by the app).
    public static var helperConfig: URL { supportDirectory.appendingPathComponent("helper-config.json") }
    /// The user's own Claude Code status line, kept running behind PulseDock's.
    public static var statusLineChain: URL { supportDirectory.appendingPathComponent("claude-statusline-chain.json") }

    public static var spool: URL { runDirectory.appendingPathComponent("spool.jsonl") }

    /// Unix socket path. Falls back to the per-user temporary directory when the default
    /// path would exceed `sun_path` (104 bytes on macOS).
    public static var socketPath: String {
        let preferred = runDirectory.appendingPathComponent("bridge.sock").path
        if preferred.utf8.count < 100 { return preferred }
        return (userTemporaryDirectory as NSString).appendingPathComponent("pulsedock-bridge.sock")
    }

    public static var userTemporaryDirectory: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0 else { return NSTemporaryDirectory() }
        return String(nulTerminated: buffer)
    }

    /// Creates `directory` if needed and makes sure only the current user can use it.
    public static func ensurePrivateDirectory(_ directory: URL) throws {
        let path = directory.path
        var info = stat()
        if lstat(path, &info) != 0 {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(path, &info) == 0 else { throw BridgeError.insecureDirectory(path) }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw BridgeError.insecureDirectory(path) }
        guard info.st_uid == getuid() else { throw BridgeError.insecureDirectory(path) }
        if (info.st_mode & 0o077) != 0 {
            guard chmod(path, 0o700) == 0 else { throw BridgeError.insecureDirectory(path) }
        }
    }
}
