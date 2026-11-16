import Cocoa
import ApplicationServices

/// One icon drawn in the menu bar, read through Accessibility.
struct MenuBarItem: Identifiable, Hashable {
    let id: String
    let pid: pid_t
    /// Bundle id of the process that owns the icon.
    let bundleID: String
    /// Bundle id of the app the macOS switch belongs to (the enclosing app for helpers).
    let switchID: String
    let appName: String
    let title: String
    /// Global coordinates, top-left origin (same space as CGEvent).
    let frame: CGRect
    /// Can go to a hidden section: not Nexo's, not part of macOS.
    let canHide: Bool
    /// Can be dragged: not part of macOS (privacy indicators, clock and Control Center stay put).
    let canMove: Bool
    /// For macOS's own icons, the module id behind it (`com.apple.menuextra.wifi` → "wifi").
    var systemExtra: String? = nil
}

/// Lists menu bar icons. On macOS 27 the bar is one MenuBarAgent window, so the window list no longer
/// shows them; each app still exposes its icons as children of its `AXExtrasMenuBar`.
enum MenuBarItemScanner {
    private static let systemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
        "com.apple.Spotlight", "com.apple.TextInputMenuAgent", "com.apple.siri", "com.apple.WindowManager"]

    /// Blocking (Accessibility IPC with a 0.25 s timeout per app): call off the main thread.
    static func scan() -> [MenuBarItem] {
        let own = ProcessInfo.processInfo.processIdentifier
        let items = NSWorkspace.shared.runningApplications.flatMap { app -> [MenuBarItem] in
            guard let bundleID = app.bundleIdentifier, !app.isTerminated else { return [] }
            return items(of: app, bundleID: bundleID, isOwn: app.processIdentifier == own)
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func items(of app: NSRunningApplication, bundleID: String, isOwn: Bool) -> [MenuBarItem] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let bar: AXUIElement = copy(element, "AXExtrasMenuBar"),
              let children: [AXUIElement] = copy(bar, kAXChildrenAttribute) else { return [] }
        let isSystem = systemOwners.contains(bundleID) || bundleID.hasPrefix("com.apple.menuextra")
        let switchID = enclosingBundleID(of: app) ?? bundleID
        let name = app.localizedName ?? bundleID
        return children.enumerated().compactMap { index, child in
            guard let frame = frame(of: child), frame.width > 0, frame.minY < 60 else { return nil }
            let title: String = copy(child, kAXTitleAttribute) ?? copy(child, kAXDescriptionAttribute) ?? ""
            // MenuBarAgent wraps each system icon in a group; the inner item carries `com.apple.menuextra.<name>`.
            let extraID: String? = isSystem ? (copy(child, kAXIdentifierAttribute) ?? innerIdentifier(of: child)) : nil
            let identifier: String = copy(child, kAXIdentifierAttribute) ?? extraID ?? "\(index)"
            return MenuBarItem(id: "\(bundleID)#\(identifier)#\(index)", pid: app.processIdentifier, bundleID: bundleID,
                switchID: switchID, appName: name, title: title, frame: frame,
                canHide: !isSystem && !isOwn, canMove: !isSystem,
                systemExtra: extraID.flatMap { $0.hasPrefix(extraPrefix) ? String($0.dropFirst(extraPrefix.count)) : nil })
        }
    }

    /// The outermost `.app` containing a helper's bundle (Docker's item comes from a helper inside
    /// Docker.app, and the switch belongs to Docker.app).
    static func enclosingBundleID(of app: NSRunningApplication) -> String? {
        guard let path = app.bundleURL?.path, let range = path.range(of: ".app/") else { return nil }
        let outer = String(path[..<range.lowerBound]) + ".app"
        guard outer != path else { return nil }
        return Bundle(path: outer)?.bundleIdentifier
    }

    private static let extraPrefix = "com.apple.menuextra."

    private static func innerIdentifier(of element: AXUIElement) -> String? {
        guard let children: [AXUIElement] = copy(element, kAXChildrenAttribute) else { return nil }
        return children.lazy.compactMap { copy($0, kAXIdentifierAttribute) as String? }.first
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copy(element, kAXPositionAttribute),
              let sizeValue: AXValue = copy(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        // CF types (AXUIElement, AXValue) bridge with `as?` only through a type-id check.
        if T.self == AXUIElement.self { return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil }
        if T.self == AXValue.self { return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil }
        return value as? T
    }
}
