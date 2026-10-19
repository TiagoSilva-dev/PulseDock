import AppKit
import Foundation

/// A persistent entry of the dock (pinned by the user). Running-but-unpinned apps are not
/// stored; they are derived from `RunningApplicationsMonitor` at runtime.
public nonisolated struct PinnedItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// An application, identified by bundle identifier when available, with its last
        /// known location as a fallback (and for apps without an identifier).
        case application(bundleIdentifier: String?, path: String)
        /// A folder shown as a stack-like shortcut that opens in Finder.
        case folder(path: String)
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public static func application(bundleIdentifier: String?, url: URL) -> PinnedItem {
        PinnedItem(kind: .application(bundleIdentifier: bundleIdentifier, path: url.path))
    }

    public static func folder(_ url: URL) -> PinnedItem {
        PinnedItem(kind: .folder(path: url.path))
    }

    public var bundleIdentifier: String? {
        if case let .application(bundleIdentifier, _) = kind { return bundleIdentifier }
        return nil
    }

    public var path: String {
        switch kind {
        case let .application(_, path): path
        case let .folder(path): path
        }
    }

    public var isApplication: Bool {
        if case .application = kind { return true }
        return false
    }

    /// True if this pinned entry refers to the given running application.
    public func matches(bundleIdentifier other: String?, url: URL?) -> Bool {
        guard case let .application(bundleIdentifier, path) = kind else { return false }
        if let bundleIdentifier, let other, bundleIdentifier == other { return true }
        if let url, url.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path { return true }
        return false
    }
}

/// Information about an application bundle on disk.
public nonisolated struct ApplicationInfo: Hashable, Sendable {
    public var bundleIdentifier: String?
    public var url: URL
    public var displayName: String
    /// `LSMultipleInstancesProhibited` is not set, so "Open New Instance" may be offered.
    public var allowsMultipleInstances: Bool

    public init(bundleIdentifier: String?, url: URL, displayName: String, allowsMultipleInstances: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.displayName = displayName
        self.allowsMultipleInstances = allowsMultipleInstances
    }

    public static func load(url: URL) -> ApplicationInfo? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let localized = bundle?.localizedInfoDictionary ?? [:]
        let name = (localized["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (localized["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let prohibited = (info["LSMultipleInstancesProhibited"] as? Bool) ?? false
        return ApplicationInfo(
            bundleIdentifier: bundle?.bundleIdentifier,
            url: url,
            displayName: name,
            allowsMultipleInstances: !prohibited
        )
    }
}
