import Cocoa
import ShortcutRecorder

/// Keep the Mac (and optionally the display) from sleeping, from the menu bar or a global shortcut.
final class KeepAwakeModule: NexoModule {
    static let id = "keepAwake"
    let title = "Keep Awake"
    let icon = "cup.and.saucer"
    private(set) var isRunning = false

    private enum Key {
        static let display = "keepAwake.keepDisplayAwake"
        static let duration = "keepAwake.defaultDuration"
        static let shortcut = "keepAwake.shortcut"
    }

    private let controller = KeepAwakeController()
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.toggle() }
    private var terminateObserver: NSObjectProtocol?

    private var keepDisplayAwake: Bool {
        get { UserDefaults.standard.bool(forKey: Key.display) }
        set { UserDefaults.standard.set(newValue, forKey: Key.display) }
    }

    private var defaultDuration: KeepAwakeController.Duration {
        get { KeepAwakeController.Duration(rawValue: UserDefaults.standard.integer(forKey: Key.duration)) ?? .indefinitely }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.duration) }
    }

    func start() {
        isRunning = true
        controller.onChange = { [weak self] in self?.refreshIndicator() }
        hotKey.register(ShortcutStore.load(Key.shortcut))
        // A process that exits releases its assertions anyway; this keeps `pmset` tidy on a normal quit.
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in self?.controller.deactivate() }
    }

    func stop() {
        isRunning = false
        hotKey.unregister()
        controller.deactivate()
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
    }

    func toggle() {
        guard !controller.isActive else {
            controller.deactivate()
            return
        }
        controller.activate(defaultDuration, keepDisplayAwake: keepDisplayAwake)
    }

    func menuItems() -> [NSMenuItem] {
        let toggleItem = NSMenuItem(title: toggleTitle(), action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = controller.isActive ? .on : .off
        toggleItem.submenu = durationsMenu()
        return [toggleItem]
    }

    func settingsView() -> NSView {
        let display = NSButton(checkboxWithTitle: "Also keep the display on", target: self, action: #selector(displayChanged(_:)))
        display.state = keepDisplayAwake ? .on : .off
        let duration = NSPopUpButton()
        KeepAwakeController.Duration.allCases.forEach { duration.addItem(withTitle: $0.title) }
        duration.selectItem(at: KeepAwakeController.Duration.allCases.firstIndex(of: defaultDuration) ?? 0)
        duration.target = self
        duration.action = #selector(durationChanged(_:))
        let shortcut = HotKeyField(key: Key.shortcut) { [weak self] in self?.hotKey.register($0) }
        return SettingsForm.stack([
            display,
            SettingsForm.row("Default duration", duration),
            SettingsForm.row("Toggle shortcut", shortcut),
            SettingsForm.note("Active assertions are listed by `pmset -g assertions` as “\(KeepAwakeController.reason)”."),
        ])
    }

    private func toggleTitle() -> String {
        guard controller.isActive else { return "Keep Awake" }
        guard let remaining = controller.remaining else { return "Keep Awake (on)" }
        return "Keep Awake (\(Self.format(remaining)) left)"
    }

    private func durationsMenu() -> NSMenu {
        let menu = NSMenu()
        for duration in KeepAwakeController.Duration.allCases {
            let item = NSMenuItem(title: duration.title, action: #selector(activateFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = duration.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let display = NSMenuItem(title: "Keep display on", action: #selector(toggleDisplayFromMenu), keyEquivalent: "")
        display.target = self
        display.state = keepDisplayAwake ? .on : .off
        menu.addItem(display)
        if controller.isActive {
            let off = NSMenuItem(title: "Turn off", action: #selector(deactivateFromMenu), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
        return menu
    }

    private func refreshIndicator() {
        NexoCore.setStatusIndicator(controller.isActive ? "cup.and.saucer.fill" : nil, owner: Self.id)
    }

    @objc private func toggleFromMenu() { toggle() }

    @objc private func deactivateFromMenu() { controller.deactivate() }

    @objc private func activateFromMenu(_ sender: NSMenuItem) {
        guard let duration = KeepAwakeController.Duration(rawValue: sender.tag) else { return }
        controller.activate(duration, keepDisplayAwake: keepDisplayAwake)
    }

    @objc private func toggleDisplayFromMenu() {
        keepDisplayAwake.toggle()
        guard controller.isActive else { return }
        let duration = controller.remaining.map(Self.closestDuration) ?? .indefinitely
        controller.activate(duration, keepDisplayAwake: keepDisplayAwake)
    }

    @objc private func displayChanged(_ sender: NSButton) {
        keepDisplayAwake = sender.state == .on
    }

    @objc private func durationChanged(_ sender: NSPopUpButton) {
        defaultDuration = KeepAwakeController.Duration.allCases[sender.indexOfSelectedItem]
    }

    /// Re-applying the display option restarts the assertion; keep roughly the time that was left.
    private static func closestDuration(_ remaining: TimeInterval) -> KeepAwakeController.Duration {
        KeepAwakeController.Duration.allCases.filter { $0 != .indefinitely }
            .min { abs(TimeInterval($0.rawValue) - remaining) < abs(TimeInterval($1.rawValue) - remaining) } ?? .indefinitely
    }

    static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
