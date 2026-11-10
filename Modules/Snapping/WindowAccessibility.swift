import Cocoa
import ApplicationServices

/// The focused window through Accessibility, plus conversions between AppKit screen coordinates
/// (bottom-left origin) and Accessibility's (top-left origin of the primary screen).
struct AXWindow {
    let element: AXUIElement

    static func focused() -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = copy(system, kAXFocusedApplicationAttribute),
              let window: AXUIElement = copy(app, kAXFocusedWindowAttribute) else { return nil }
        return AXWindow(element: window)
    }

    var frame: CGRect? {
        guard let positionValue: AXValue = Self.copy(element, kAXPositionAttribute),
              let sizeValue: AXValue = Self.copy(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Size, then position, then size again: some apps clamp the size to the screen they are on, so
    /// moving across displays needs the second pass (same approach as Rectangle).
    func setFrame(_ frame: CGRect) {
        setSize(frame.size)
        setPosition(frame.origin)
        setSize(frame.size)
    }

    private func setPosition(_ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

enum ScreenSpace {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AppKit rect → Accessibility rect.
    static func toAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Accessibility rect → AppKit rect.
    static func toAppKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen holding most of `axRect`.
    static func screen(containing axRect: CGRect) -> NSScreen? {
        let rect = toAppKit(axRect)
        return NSScreen.screens.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
    }

    static func usableArea(_ screen: NSScreen) -> CGRect {
        toAX(screen.visibleFrame)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
