import Cocoa

/// Reorders menu bar icons the way a person does: ⌘-drag. There is no API for it; MenuBarAgent
/// keeps the new position itself. Events carry a marker so Nexo's own taps can tell them apart.
enum MenuBarDragger {
    static let marker: Int64 = 0x4E45_584F

    /// Moves `item` past its neighbour `target` (to its left or right). Blocking (~250 ms): call off main.
    static func move(_ item: MenuBarItem, past target: MenuBarItem, toLeft: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location ?? .zero
        let start = CGPoint(x: item.frame.midX, y: item.frame.midY)
        // Past the neighbour's middle, but still inside it, so MenuBarAgent inserts on that side.
        let end = CGPoint(x: toLeft ? target.frame.minX + 2 : target.frame.maxX - 2, y: target.frame.midY)
        post(.mouseMoved, start, [], source)
        usleep(20_000)
        post(.leftMouseDown, start, .maskCommand, source)
        usleep(40_000)
        let steps = 12
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y), .maskCommand, source)
            usleep(15_000)
        }
        usleep(40_000)
        post(.leftMouseUp, end, .maskCommand, source)
        usleep(20_000)
        post(.mouseMoved, original, [], source)
        CGWarpMouseCursorPosition(original)
    }

    private static func post(_ type: CGEventType, _ point: CGPoint, _ flags: CGEventFlags, _ source: CGEventSource?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }
}
