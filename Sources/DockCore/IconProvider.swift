import AppKit
import Foundation

/// Resolves and caches icons as fixed-resolution bitmaps so the dock can scale them on the
/// GPU every frame without re-rasterising multi-representation `NSImage`s.
public final class IconProvider {
    public static let shared = IconProvider()

    /// Pixel size of cached bitmaps: enough for a 72 pt icon magnified 2× on a Retina display.
    public let pixelSize: Int
    private let cache = NSCache<NSString, NSImage>()

    public init(pixelSize: Int = 288) {
        self.pixelSize = pixelSize
        cache.countLimit = 256
    }

    public func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let source = NSWorkspace.shared.icon(forFile: path)
        let image = rasterize(source)
        cache.setObject(image, forKey: key)
        return image
    }

    public func icon(for application: NSRunningApplication) -> NSImage {
        if let url = application.bundleURL {
            return icon(forPath: url.path)
        }
        let key = "pid:\(application.processIdentifier)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = rasterize(application.icon ?? NSWorkspace.shared.icon(for: .application))
        cache.setObject(image, forKey: key)
        return image
    }

    /// Icon of a system resource (for example the Trash), looked up from CoreTypes at runtime.
    public func systemIcon(named name: String, fallback: NSImage.Name? = nil) -> NSImage {
        let key = "system:\(name)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(name).icns"
        let base = NSImage(contentsOfFile: path)
            ?? fallback.flatMap { NSImage(named: $0) }
            ?? NSWorkspace.shared.icon(for: .folder)
        let image = rasterize(base)
        cache.setObject(image, forKey: key)
        return image
    }

    public func invalidate(path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    /// Draws the icon once into a @2x bitmap (point size = half the pixel size).
    private func rasterize(_ image: NSImage) -> NSImage {
        let size = NSSize(width: Double(pixelSize) / 2, height: Double(pixelSize) / 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }
}
