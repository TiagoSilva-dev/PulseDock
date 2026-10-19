import Foundation

/// A proposed change to an agent configuration file, shown to the user before anything is
/// written. Applying it re-checks that the file did not change since the plan was made.
public struct ConfigChangePlan: Sendable, Equatable {
    public var fileURL: URL
    /// File contents when the plan was made (`nil` if the file did not exist).
    public var originalText: String?
    public var newText: String
    public var addedEvents: [String]
    public var removedHandlers: Int
    public var preservedForeignHandlers: Int
    /// True when applying the plan would not change the file.
    public var isNoOp: Bool { originalText == newText }

    public init(fileURL: URL, originalText: String?, newText: String, addedEvents: [String], removedHandlers: Int, preservedForeignHandlers: Int) {
        self.fileURL = fileURL
        self.originalText = originalText
        self.newText = newText
        self.addedEvents = addedEvents
        self.removedHandlers = removedHandlers
        self.preservedForeignHandlers = preservedForeignHandlers
    }

    /// Line-level preview: lines only in the old file get "-", lines only in the new one "+".
    public var previewLines: [String] {
        let old = (originalText ?? "").components(separatedBy: "\n")
        let new = newText.components(separatedBy: "\n")
        return LineDiff.diff(old: old, new: new)
    }
}

public enum ConfigEditError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case notAnObject
    case unexpectedHooksShape
    case changedSinceReview
    case writeFailed(String)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(message): "The configuration file could not be read: \(message)"
        case .notAnObject: "The configuration file is not a JSON object."
        case .unexpectedHooksShape: "The existing \"hooks\" section has an unexpected format."
        case .changedSinceReview: "The file changed after the preview. Review the changes again."
        case let .writeFailed(message): "Could not write the configuration file: \(message)"
        case let .validationFailed(message): "The written file did not validate: \(message)"
        }
    }
}

/// Safe read/backup/write for small configuration files.
public enum ConfigFileIO {
    public static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw ConfigEditError.unreadable("not UTF-8") }
            return text
        } catch let error as ConfigEditError {
            throw error
        } catch {
            throw ConfigEditError.unreadable(error.localizedDescription)
        }
    }

    /// Copies the current file into `backupsDirectory` (mode 0600) and returns the copy.
    @discardableResult
    public static func backup(_ url: URL, into backupsDirectory: URL, prefix: String) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var destination = backupsDirectory.appendingPathComponent("\(prefix)-\(formatter.string(from: Date())).\(url.pathExtension.isEmpty ? "bak" : url.pathExtension)")
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = backupsDirectory.appendingPathComponent("\(prefix)-\(formatter.string(from: Date()))-\(counter).\(url.pathExtension)")
            counter += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    /// Writes atomically (temporary file + rename), keeping the original permissions.
    public static func writeAtomically(_ text: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var permissions: NSNumber = 0o644
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let existing = attributes[.posixPermissions] as? NSNumber {
                permissions = existing
            }
            let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).pulsedock-\(UUID().uuidString.prefix(8))")
            try Data(text.utf8).write(to: temporary, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            if rename(temporary.path, url.path) != 0 {
                let code = errno
                try? FileManager.default.removeItem(at: temporary)
                throw ConfigEditError.writeFailed(String(cString: strerror(code)))
            }
        } catch let error as ConfigEditError {
            throw error
        } catch {
            throw ConfigEditError.writeFailed(error.localizedDescription)
        }
    }
}

/// Minimal line diff (longest common subsequence) for previews of small files.
public enum LineDiff {
    public static func diff(old: [String], new: [String]) -> [String] {
        let n = old.count
        let m = new.count
        guard n * m <= 4_000_000 else {
            return old.map { "- " + $0 } + new.map { "+ " + $0 }
        }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [String] = []
        var i = 0
        var j = 0
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                result.append("  " + old[i]); i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                result.append("+ " + new[j]); j += 1
            } else {
                result.append("- " + old[i]); i += 1
            }
        }
        return result
    }
}
