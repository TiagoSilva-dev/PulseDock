import AppKit
import CoreGraphics
import Foundation

/// Which display hosts the dock.
public nonisolated enum DisplayPreference: Codable, Hashable, Sendable {
    /// The display with the menu bar.
    case primary
    /// The display the pointer is on when it touches the bottom edge.
    case followPointer
    /// A specific display, identified by its stable UUID.
    case specific(uuid: String, name: String)
}

public struct DisplayInfo: Identifiable, Hashable {
    public var id: String { uuid }
    public var uuid: String
    public var name: String
    public var displayID: CGDirectDisplayID
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var backingScaleFactor: Double
    public var isPrimary: Bool
}

public enum DisplayLocator {
    public static func displays() -> [DisplayInfo] {
        let primaryID = NSScreen.screens.first.flatMap(displayID(of:))
        return NSScreen.screens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            return DisplayInfo(
                uuid: uuid(of: id) ?? "display-\(id)",
                name: screen.localizedName,
                displayID: id,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                backingScaleFactor: screen.backingScaleFactor,
                isPrimary: id == primaryID
            )
        }
    }

    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    public static func uuid(of displayID: CGDirectDisplayID) -> String? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public static func screen(withUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { screen in
            displayID(of: screen).flatMap { self.uuid(of: $0) } == uuid
        }
    }

    public static func screenContaining(point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Resolves the preference to a screen, falling back to the primary display when the
    /// preferred one is disconnected.
    public static func resolve(_ preference: DisplayPreference, lastPointerScreen: NSScreen?) -> NSScreen? {
        switch preference {
        case .primary:
            return NSScreen.screens.first
        case .followPointer:
            return lastPointerScreen ?? screenContaining(point: NSEvent.mouseLocation) ?? NSScreen.screens.first
        case let .specific(uuid, _):
            return screen(withUUID: uuid) ?? NSScreen.screens.first
        }
    }

    /// True if the frontmost application covers the whole screen with a window, which is
    /// how borderless-fullscreen games and video players behave. Uses only window bounds and
    /// owner PIDs, which do not require Screen Recording permission.
    public static func frontmostAppCoversScreen(_ screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = front.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // CGWindow bounds use a top-left origin on the primary display.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        let target = CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if bounds.insetBy(dx: -1, dy: -1).contains(target) {
                return true
            }
        }
        return false
    }
}
