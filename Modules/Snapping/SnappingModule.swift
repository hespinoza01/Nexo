import Cocoa
import Carbon.HIToolbox
import ShortcutRecorder

/// Move and resize the focused window with shortcuts, or by dragging it to a screen edge.
final class SnappingModule: NexoModule {
    static let id = "snapping"
    let title = "Window Snapping"
    let icon = "rectangle.split.2x1"
    let permissions: [ModulePermission] = [.accessibility]
    private(set) var isRunning = false

    private enum Key {
        static let gap = "snapping.gap"
        static let dragSnap = "snapping.dragSnap"
        static let defaultsSeeded = "snapping.defaultsSeeded"
        static func shortcut(_ action: SnapAction) -> String { "snapping.shortcut.\(action.rawValue)" }
    }

    private var hotKeys = [SnapAction: GlobalHotKey]()
    private let dragSnapper = DragSnapper()

    private var gap: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: Key.gap)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: Key.gap) }
    }

    private var dragSnapEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.dragSnap) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.dragSnap) }
    }

    func start() {
        isRunning = true
        seedDefaultShortcutsOnce()
        for action in SnapAction.allCases {
            let hotKey = GlobalHotKey { [weak self] in self?.perform(action) }
            hotKey.register(ShortcutStore.load(Key.shortcut(action)))
            hotKeys[action] = hotKey
        }
        dragSnapper.onSnap = { [weak self] action, window in self?.perform(action, on: window) }
        if dragSnapEnabled { dragSnapper.start() }
    }

    func stop() {
        isRunning = false
        hotKeys.values.forEach { $0.unregister() }
        hotKeys.removeAll()
        dragSnapper.stop()
    }

    func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Move Window", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for action in SnapAction.allCases {
            let entry = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = action.rawValue
            if let shortcut = ShortcutStore.load(Key.shortcut(action)) {
                entry.keyEquivalent = shortcut.charactersIgnoringModifiers ?? ""
                entry.keyEquivalentModifierMask = shortcut.modifierFlags
            }
            submenu.addItem(entry)
            if [.bottomHalf, .lastTwoThirds, .bottomRight, .center].contains(action) { submenu.addItem(.separator()) }
        }
        item.submenu = submenu
        return [item]
    }

    func settingsView() -> NSView {
        let gapField = NSTextField(string: "\(Int(gap))")
        gapField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        gapField.target = self
        gapField.action = #selector(gapChanged(_:))
        let drag = NSButton(checkboxWithTitle: "Snap when dragging a window to a screen edge", target: self, action: #selector(dragToggled(_:)))
        drag.state = dragSnapEnabled ? .on : .off
        var views: [NSView] = [drag, SettingsForm.row("Gap between windows (pt)", gapField)]
        if Self.nativeTilingEnabled() {
            views.append(SettingsForm.note("⚠︎ macOS window tiling is on (System Settings › Desktop & Dock › “Drag windows to screen edges to tile”). Turn it off to avoid both snapping at once."))
        }
        views.append(SettingsForm.header("Shortcuts"))
        let grid = SnapAction.allCases.map { action -> NSView in
            let label = NSTextField(labelWithString: action.title)
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let field = HotKeyField(key: Key.shortcut(action)) { [weak self] in self?.hotKeys[action]?.register($0) }
            return NSStackView(views: [label, field])
        }
        views.append(SettingsForm.stack(grid, spacing: 4))
        return SettingsForm.stack(views)
    }

    func perform(_ action: SnapAction, on window: AXWindow? = nil) {
        guard AXIsProcessTrusted() else {
            PermissionCenter.request(.accessibility)
            return
        }
        guard let window = window ?? AXWindow.focused(), let frame = window.frame,
              let screen = ScreenSpace.screen(containing: frame) else { return }
        guard action.movesAcrossDisplays else {
            window.setFrame(SnapGeometry.frame(action, window: frame, area: ScreenSpace.usableArea(screen), gap: gap))
            return
        }
        let screens = NSScreen.screens
        guard screens.count > 1, let index = screens.firstIndex(of: screen) else { return }
        let target = screens[(index + (action == .nextDisplay ? 1 : screens.count - 1)) % screens.count]
        window.setFrame(SnapGeometry.move(frame, from: ScreenSpace.usableArea(screen), to: ScreenSpace.usableArea(target)))
    }

    /// macOS 15+ tiling by edge drag (`com.apple.WindowManager` EnableTilingByEdgeDrag, on by default).
    static func nativeTilingEnabled() -> Bool {
        let defaults = UserDefaults(suiteName: "com.apple.WindowManager")
        return defaults?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
    }

    /// Rectangle-style defaults (⌃⌥ + arrows/letters), written once so the user can clear them.
    private func seedDefaultShortcutsOnce() {
        guard !UserDefaults.standard.bool(forKey: Key.defaultsSeeded) else { return }
        UserDefaults.standard.set(true, forKey: Key.defaultsSeeded)
        let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]
        let defaults: [(SnapAction, KeyCode, NSEvent.ModifierFlags)] = [
            (.leftHalf, .leftArrow, ctrlOpt), (.rightHalf, .rightArrow, ctrlOpt),
            (.topHalf, .upArrow, ctrlOpt), (.bottomHalf, .downArrow, ctrlOpt),
            (.firstThird, .ansiD, ctrlOpt), (.centerThird, .ansiF, ctrlOpt), (.lastThird, .ansiG, ctrlOpt),
            (.firstTwoThirds, .ansiE, ctrlOpt), (.lastTwoThirds, .ansiT, ctrlOpt),
            (.topLeft, .ansiU, ctrlOpt), (.topRight, .ansiI, ctrlOpt), (.bottomLeft, .ansiJ, ctrlOpt), (.bottomRight, .ansiK, ctrlOpt),
            (.maximize, .return, ctrlOpt), (.center, .ansiC, ctrlOpt),
            (.nextDisplay, .rightArrow, ctrlOpt.union(.command)), (.previousDisplay, .leftArrow, ctrlOpt.union(.command)),
        ]
        for (action, code, modifiers) in defaults {
            ShortcutStore.save(Shortcut(code: code, modifierFlags: modifiers, characters: nil, charactersIgnoringModifiers: nil), Key.shortcut(action))
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = SnapAction(rawValue: raw) else { return }
        perform(action)
    }

    @objc private func gapChanged(_ sender: NSTextField) {
        gap = CGFloat(max(0, min(60, sender.integerValue)))
        sender.integerValue = Int(gap)
    }

    @objc private func dragToggled(_ sender: NSButton) {
        dragSnapEnabled = sender.state == .on
        dragSnapEnabled ? dragSnapper.start() : dragSnapper.stop()
    }
}

/// Watches global mouse drags; when a window is being dragged and the cursor reaches a screen edge it
/// shows a preview of the target frame, and snaps on release. Window drags are recognised by the focused
/// window's position changing while the button is down, since macOS doesn't announce them.
final class DragSnapper {
    var onSnap: ((SnapAction, AXWindow) -> Void)?
    private var monitors = [Any]()
    private var dragged: (window: AXWindow, startOrigin: CGPoint)?
    private var target: SnapAction?
    private let overlay = SnapOverlay()

    func start() {
        guard monitors.isEmpty else { return }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.mouseDown() },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.mouseDragged() },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() },
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func mouseDown() {
        guard AXIsProcessTrusted(), let window = AXWindow.focused(), let frame = window.frame else { return }
        dragged = (window, frame.origin)
    }

    private func mouseDragged() {
        guard let dragged else { return }
        let cursor = ScreenSpace.toAX(CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) else { return }
        let frame = ScreenSpace.toAX(screen.frame)
        let action = SnapGeometry.dragTarget(cursor, area: frame)
        guard action != target else { return }
        target = action
        guard let action, let current = dragged.window.frame, current.origin != dragged.startOrigin else {
            overlay.hide()
            return
        }
        let preview = SnapGeometry.frame(action, window: current, area: ScreenSpace.usableArea(screen))
        overlay.show(ScreenSpace.toAppKit(preview))
    }

    private func mouseUp() {
        defer { reset() }
        guard let dragged, let target, let frame = dragged.window.frame, frame.origin != dragged.startOrigin else { return }
        let window = dragged.window
        // Let the window server finish the drag before resizing, or the drag's last move wins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.onSnap?(target, window) }
    }

    private func reset() {
        dragged = nil
        target = nil
        overlay.hide()
    }
}

/// Translucent rectangle previewing where the window will land.
final class SnapOverlay {
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        window.contentView = view
        return window
    }()

    func show(_ frame: CGRect) {
        window.setFrame(frame.insetBy(dx: 6, dy: 6), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}
