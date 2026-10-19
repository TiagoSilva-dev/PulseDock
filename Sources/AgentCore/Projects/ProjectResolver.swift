import Foundation

/// A project derived automatically from a working directory (no manual registration).
public struct ProjectInfo: Sendable, Hashable, Codable {
    public var name: String
    public var rootPath: String
    /// Deterministic hue in 0..<1 used for the small project identifier.
    public var hue: Double
    public var monogram: String

    public init(name: String, rootPath: String) {
        self.name = name
        self.rootPath = rootPath
        let hash = StableHasher.hash(rootPath)
        let value = UInt64(hash, radix: 16) ?? 0
        self.hue = Double(value % 360) / 360
        let letters = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap(\.first)
        let initials = letters.prefix(2).map { String($0).uppercased() }.joined()
        self.monogram = initials.isEmpty ? String(name.prefix(1)).uppercased() : initials
    }
}

/// Finds the repository root of a path (the nearest ancestor containing `.git`) and caches
/// the answer. File-system access is injectable for tests.
public final class ProjectResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: ProjectInfo] = [:]
    private let fileExists: @Sendable (String) -> Bool
    private let homeDirectory: String

    public init(
        homeDirectory: String = NSHomeDirectory(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.homeDirectory = homeDirectory
        self.fileExists = fileExists
    }

    public func resolve(_ path: String?) -> ProjectInfo? {
        guard let path, !path.isEmpty else { return nil }
        let standardized = (path as NSString).standardizingPath
        lock.lock()
        if let cached = cache[standardized] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var root = standardized
        var candidate = standardized
        for _ in 0..<12 {
            if fileExists((candidate as NSString).appendingPathComponent(".git")) {
                root = candidate
                break
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || candidate == homeDirectory || parent.isEmpty { break }
            candidate = parent
        }
        let name = (root as NSString).lastPathComponent
        let info = ProjectInfo(name: name.isEmpty ? root : name, rootPath: root)
        lock.lock()
        cache[standardized] = info
        lock.unlock()
        return info
    }
}
