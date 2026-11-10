import Cocoa

/// Nexo module wrapping the AltTab-derived window switcher.
/// The switcher's model, taps and background threads are process-lifetime singletons that were never
/// designed to be torn down, so `stop()` only disables the global shortcuts and hides the UI; the
/// heavy launch runs once per process, on the first `start()`.
final class SwitcherModule: NexoModule {
    static let id = "switcher"
    let title = "Window Switcher"
    let icon = "rectangle.on.rectangle"
    let permissions: [ModulePermission] = [.accessibility, .screenRecording]
    private(set) var isRunning = false
    private static var launched = false

    func start() {
        isRunning = true
        guard Self.launched else {
            Self.launched = true
            App.startSwitcher()
            return
        }
        KeyboardEvents.toggleGlobalShortcuts(false)
    }

    func stop() {
        isRunning = false
        App.hideUi()
        KeyboardEvents.toggleGlobalShortcuts(true)
    }

    func menuItems() -> [NSMenuItem] {
        Menubar.moduleMenuItems()
    }

    func settingsView() -> NSView {
        let info = NSTextField(wrappingLabelWithString:
            "Shortcuts, appearance, filters and exceptions for the window switcher live in their own window.")
        let button = NSButton(title: "Open Switcher Settings…", target: self, action: #selector(openSwitcherSettings))
        let stack = NSStackView(views: [info, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    @objc private func openSwitcherSettings() {
        App.showSettingsWindow()
    }
}
