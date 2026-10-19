import AppKit
import Foundation

/// Small LaunchServices lookups used when resolving pinned items.
public enum NSWorkspaceLookup {
    public static func url(forBundleIdentifier identifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    /// Current location of a pinned application: by bundle identifier first (the app may
    /// have moved or been updated), then by its last known path.
    public static func resolve(_ item: PinnedItem) -> URL? {
        switch item.kind {
        case let .application(bundleIdentifier, path):
            if let bundleIdentifier, let url = url(forBundleIdentifier: bundleIdentifier) { return url }
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        case let .folder(path):
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
    }

    public static func displayName(for url: URL) -> String {
        if url.pathExtension == "app", let info = ApplicationInfo.load(url: url) { return info.displayName }
        return FileManager.default.displayName(atPath: url.path)
    }
}
