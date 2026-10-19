import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A window of another application, reachable through the Accessibility API.
public struct AXWindowHandle: Identifiable {
    public let id: Int
    public let element: AXUIElement
    public let title: String
    public let isMinimized: Bool
}

/// Window listing for dock menus.
///
/// Without any permission PulseDock only counts on-screen windows (bounds and owner from
/// `CGWindowListCopyWindowInfo`). Titles, minimized windows and per-window raising use the
/// Accessibility API, which is optional and requested only from the context where the user
/// asks for it.
public enum WindowInventory {
    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    public static func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Number of normal, on-screen windows owned by the process. No permission required.
    public static func onScreenWindowCount(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        return list.reduce(into: 0) { count, info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40 else { return }
            count += 1
        }
    }

    /// Windows of an app through Accessibility, or `nil` when access was not granted.
    public static func windows(pid: pid_t) -> [AXWindowHandle]? {
        guard isAccessibilityTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        var result: [AXWindowHandle] = []
        for (index, element) in elements.enumerated() {
            let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)
            guard subrole == nil || subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String) else { continue }
            let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? ""
            let minimized = boolAttribute(element, kAXMinimizedAttribute as CFString) ?? false
            result.append(AXWindowHandle(id: index, element: element, title: title, isMinimized: minimized))
        }
        return result
    }

    /// Restores a minimized window if needed, raises it and brings its app forward.
    public static func focus(_ window: AXWindowHandle, pid: pid_t) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
