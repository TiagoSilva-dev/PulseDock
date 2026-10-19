import AppKit
import DockCore
import DockRendering
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import WidgetCore

// MARK: - Shared rows

/// A file row that can be opened, dragged out to another app or revealed in Finder.
struct FileRow: View {
    let url: URL
    var subtitle: String?
    var trailing: (() -> AnyView)?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconProvider.shared.icon(forPath: url.path)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(PulseTypography.panelBody).lineLimit(1).truncationMode(.middle)
                if let subtitle { Text(subtitle).font(PulseTypography.panelCaption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            trailing?()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button(tr("files.open", "Open")) { NSWorkspace.shared.open(url) }
            Button(tr("files.reveal", "Show in Finder")) { AppLauncher.revealInFinder(url) }
            Button(tr("files.copyPath", "Copy Path")) { Pasteboard.copy(url.path) }
        }
        .help(url.path)
    }
}

enum FileText {
    static func subtitle(_ item: FolderItem, now: Date) -> String {
        var parts = [Formatting.relative(item.addedAt, now: now)]
        if let size = item.size, !item.isDirectory {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Downloads (or any folder)

struct FilesTile: View {
    let watcher: FolderWatcher
    let lastSeen: Date?
    let theme: Theme

    var body: some View {
        let fresh = watcher.items.filter { $0.addedAt > (lastSeen ?? .distantFuture) }.count
        let icon = IconProvider.shared.icon(forPath: watcher.folder.path)
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .padding(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if fresh > 0 {
                    Text("\(min(fresh, 99))")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4.5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(theme.tone(.failure)))
                }
            }
            .accessibilityLabel(watcher.folder.lastPathComponent)
            .accessibilityValue(trp("files.newCount", one: "%ld new item", other: "%ld new items", fresh))
    }
}

struct FilesPanel: View {
    let watcher: FolderWatcher
    let theme: Theme
    let accessibility: AccessibilityOptions
    let chooseFolder: () -> Void

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: FileManager.default.displayName(atPath: watcher.folder.path)) {
            if watcher.accessDenied {
                AccessPrompt(text: tr("files.denied", "macOS did not allow PulseDock to read this folder. Allow it in System Settings › Privacy & Security › Files and Folders."),
                             button: tr("common.openSystemSettings", "Open System Settings"), theme: theme) {
                    SystemSettingsLink.open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
                }
            } else if watcher.items.isEmpty {
                Text(tr("files.empty", "This folder is empty.")).font(PulseTypography.panelBody).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(watcher.items) { item in
                        FileRow(url: item.url, subtitle: FileText.subtitle(item, now: Date()))
                    }
                }
            }
            HStack {
                Button(tr("files.openFolder", "Open in Finder")) { NSWorkspace.shared.open(watcher.folder) }
                Spacer()
                Button(tr("files.chooseFolder", "Choose Folder…"), action: chooseFolder)
            }
            .buttonStyle(.link)
            .font(PulseTypography.panelCaption)
            Text(tr("files.footer", "Drag a file out of this list to use it anywhere."))
                .font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Shelf

struct ShelfTile: View {
    let count: Int
    let theme: Theme

    var body: some View {
        SymbolTile(symbol: count > 0 ? "tray.full.fill" : "tray", theme: theme, tint: count > 0 ? theme.tone(.working) : nil, badge: count)
            .accessibilityLabel(tr("widget.shelf", "Shelf"))
            .accessibilityValue(trp("shelf.count", one: "%ld item", other: "%ld items", count))
    }
}

struct ShelfPanel: View {
    let data: WidgetDataStore
    let theme: Theme
    let accessibility: AccessibilityOptions
    let airDrop: ([URL]) -> Void

    var body: some View {
        let urls = data.data.shelf.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.shelf", "Shelf")) {
            if urls.isEmpty {
                Text(tr("shelf.empty", "Drop files on the Shelf tile to keep them at hand, then drag them out wherever you need them. Files are not moved or copied."))
                    .font(PulseTypography.panelBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(urls, id: \.self) { url in
                        FileRow(url: url, subtitle: url.deletingLastPathComponent().lastPathComponent) {
                            AnyView(Button {
                                data.update { $0.shelf.removeAll { $0 == url.path } }
                            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(tr("shelf.remove", "Remove from Shelf")))
                        }
                    }
                }
            }
            if !urls.isEmpty {
                HStack {
                    PillButton(title: tr("shelf.airDrop", "AirDrop All"), symbol: "airplayaudio", tint: theme.tone(.working)) { airDrop(urls) }
                    Spacer()
                    Button(tr("shelf.clear", "Clear Shelf")) { data.update { $0.shelf.removeAll() } }
                        .buttonStyle(.link)
                        .font(PulseTypography.panelCaption)
                }
            }
        }
    }
}

// MARK: - AirDrop

struct AirDropTile: View {
    let isTargeted: Bool
    let theme: Theme

    var body: some View {
        SymbolTile(symbol: "airplayaudio", theme: theme, tint: Color(nsColor: .systemBlue))
            .scaleEffect(isTargeted ? 1.12 : 1)
            .accessibilityLabel(tr("widget.airDrop", "AirDrop"))
            .accessibilityHint(tr("airDrop.hint", "Drop files here to send them with AirDrop."))
    }
}

struct AirDropPanel: View {
    let theme: Theme
    let accessibility: AccessibilityOptions
    let send: ([URL]) -> Void

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.airDrop", "AirDrop")) {
            Text(tr("airDrop.body", "Drop files on the AirDrop tile to send them to a nearby Mac, iPhone or iPad."))
                .font(PulseTypography.panelBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PillButton(title: tr("airDrop.choose", "Choose Files…"), symbol: "doc.badge.plus", prominent: true, tint: Color(nsColor: .systemBlue)) {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = true
                NSApp.activate()
                if panel.runModal() == .OK { send(panel.urls) }
            }
        }
    }
}

// MARK: - Screenshots

struct ScreenshotsTile: View {
    let watcher: FolderWatcher
    let theme: Theme

    var body: some View {
        Group {
            if let latest = watcher.items.first {
                FileThumbnail(url: latest.url, size: CGSize(width: 96, height: 96))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .padding(5)
                    .onDrag { NSItemProvider(contentsOf: latest.url) ?? NSItemProvider() }
            } else {
                SymbolTile(symbol: "camera.viewfinder", theme: theme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(tr("widget.screenshots", "Screenshots"))
    }
}

struct ScreenshotsPanel: View {
    let watcher: FolderWatcher
    let theme: Theme
    let accessibility: AccessibilityOptions
    @State private var copied = TransientFlag()

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.screenshots", "Screenshots")) {
            if watcher.accessDenied {
                AccessPrompt(text: tr("screenshots.denied", "macOS did not allow PulseDock to read the folder where screenshots are saved."),
                             button: tr("common.openSystemSettings", "Open System Settings"), theme: theme) {
                    SystemSettingsLink.open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
                }
            } else if watcher.items.isEmpty {
                Text(tr("screenshots.empty", "No screenshots yet. Press ⇧⌘4 to take one."))
                    .font(PulseTypography.panelBody).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 8), count: 3), spacing: 8) {
                    ForEach(watcher.items) { item in
                        FileThumbnail(url: item.url, size: CGSize(width: 208, height: 140))
                            .frame(width: 104, height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .onTapGesture { NSWorkspace.shared.open(item.url) }
                            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                            .contextMenu {
                                Button(tr("screenshots.copy", "Copy Image")) {
                                    if let image = NSImage(contentsOf: item.url) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.writeObjects([image])
                                        copied.show(tr("common.copied", "Copied"))
                                    }
                                }
                                Button(tr("files.reveal", "Show in Finder")) { AppLauncher.revealInFinder(item.url) }
                                Button(tr("screenshots.trash", "Move to Trash")) { AppLauncher.moveToTrash([item.url]) }
                            }
                            .help(item.url.lastPathComponent)
                    }
                }
            }
            HStack {
                Text(copied.value ?? tr("screenshots.footer", "Drag a screenshot into any app. Right-click for more."))
                    .font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
                Spacer()
                Button(tr("files.openFolder", "Open in Finder")) { NSWorkspace.shared.open(watcher.folder) }
                    .buttonStyle(.link).font(PulseTypography.panelCaption)
            }
        }
    }
}

/// A Quick Look thumbnail generated off the main thread, cached by URL and size.
struct FileThumbnail: View {
    let url: URL
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: IconProvider.shared.icon(forPath: url.path)).resizable().aspectRatio(contentMode: .fit).padding(8)
            }
        }
        .task(id: url) { image = await ThumbnailCache.shared.thumbnail(for: url, size: size) }
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let key = "\(url.path)#\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}
