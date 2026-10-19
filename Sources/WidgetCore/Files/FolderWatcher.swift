import CoreServices
import Foundation
import Observation

public nonisolated struct FolderItem: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public var url: URL
    public var addedAt: Date
    public var size: Int64?
    public var isDirectory: Bool
}

/// The newest items of a folder (Downloads, Screenshots…), refreshed by a kernel vnode event
/// when the folder changes. No polling.
@Observable
public final class FolderWatcher {
    public private(set) var items: [FolderItem] = []
    public private(set) var accessDenied = false
    public let folder: URL
    /// Only files whose name matches (for example screenshots); nil keeps everything.
    @ObservationIgnored public var filter: (@Sendable (URL) -> Bool)?
    public var limit: Int
    public var isActive = false {
        didSet { if isActive != oldValue { isActive ? start() : stop() } }
    }

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var descriptor: Int32 = -1
    @ObservationIgnored private var pending: DispatchWorkItem?

    public init(folder: URL, limit: Int = 12, filter: (@Sendable (URL) -> Bool)? = nil) {
        self.folder = folder
        self.limit = limit
        self.filter = filter
    }

    private func start() {
        reload()
        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        let fd = descriptor
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    /// Downloads write a file in several steps; coalesce bursts.
    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public func reload() {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey, .isDirectoryKey, .isHiddenKey]
        let folder = folder
        let filter = filter
        let limit = limit
        Task.detached(priority: .utility) {
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                let items: [FolderItem] = urls.compactMap { url in
                    guard filter?(url) ?? true else { return nil }
                    // Partial downloads are not useful yet.
                    if ["download", "crdownload", "part"].contains(url.pathExtension) { return nil }
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    let date = values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast
                    return FolderItem(url: url, addedAt: date, size: values?.fileSize.map(Int64.init), isDirectory: values?.isDirectory ?? false)
                }
                let newest = Array(items.sorted { $0.addedAt > $1.addedAt }.prefix(limit))
                await MainActor.run {
                    self.items = newest
                    self.accessDenied = false
                }
            } catch {
                await MainActor.run {
                    self.items = []
                    self.accessDenied = true
                }
            }
        }
    }

    /// Where `screencapture` saves screenshots (the user's choice in the Screenshot app),
    /// Desktop by default.
    public nonisolated static func screenshotsFolder() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !location.isEmpty {
            let expanded = (location as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Screenshots and screen recordings named by macOS (any language) are images or movies
    /// carrying the "screen capture" metadata flag; checking it avoids listing every image on
    /// the Desktop.
    public nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        let types = ["png", "jpg", "jpeg", "heic", "tiff", "mov", "mp4"]
        guard types.contains(url.pathExtension.lowercased()) else { return false }
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let flag = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool else {
            // Spotlight may not have indexed a brand-new file; fall back to the default prefixes.
            let name = url.lastPathComponent.lowercased()
            return ["screenshot", "captura de tela", "screen recording", "gravação de tela", "bildschirmfoto"].contains { name.hasPrefix($0) }
        }
        return flag
    }
}
