import Foundation

/// Lists installed applications on demand (for the "Add to Dock" picker). Runs off the main
/// thread and only scans the standard application folders, two levels deep.
public nonisolated enum InstalledApplications {
    public static let searchRoots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
    ]

    public static func scan(roots: [URL] = searchRoots) async -> [ApplicationInfo] {
        await Task.detached(priority: .utility) {
            var seen = Set<String>()
            var result: [ApplicationInfo] = []
            let fileManager = FileManager.default
            func visit(_ directory: URL, depth: Int) {
                guard let contents = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { return }
                for url in contents {
                    if url.pathExtension == "app" {
                        let path = url.standardizedFileURL.path
                        guard !seen.contains(path), let info = ApplicationInfo.load(url: url) else { continue }
                        seen.insert(path)
                        result.append(info)
                    } else if depth > 0, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        visit(url, depth: depth - 1)
                    }
                }
            }
            for root in roots { visit(root, depth: 1) }
            return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }.value
    }
}
