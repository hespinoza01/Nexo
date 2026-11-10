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
        App.isSwitcherEnabled = true
        guard Self.launched else {
            Self.launched = true
            App.startSwitcher()
            return
        }
        guard App.didContinueAppLaunch else { return }
        KeyboardEvents.toggleGlobalShortcuts(false)
        ControlsTab.toggleNativeCommandTabIfNeeded()
        // Re-apply the per-app exceptions for whatever is frontmost right now.
        if let pid = Applications.frontmostPid, let app = Applications.findOrCreate(pid) {
            App.checkIfShortcutsShouldBeDisabled(app.focusedWindow, app)
        }
    }

    /// `App.isSwitcherEnabled` is what makes this durable: the switcher re-evaluates its shortcuts on
    /// every app/window activation and would otherwise re-register them.
    func stop() {
        isRunning = false
        App.isSwitcherEnabled = false
        App.hideUi()
        KeyboardEvents.toggleGlobalShortcuts(true)
        SettingsWindow.shared?.close()
        // Give ⌘Tab back to macOS while the switcher is off.
        if App.didContinueAppLaunch { setNativeCommandTabEnabled(true) }
    }

    func menuItems() -> [NSMenuItem] {
        Menubar.moduleMenuItems()
    }

    func settingsView() -> NSView {
        let info = NSTextField(wrappingLabelWithString:
            isRunning ? "Shortcuts, appearance, filters and exceptions for the window switcher live in their own window."
                : "Enable the module to configure the window switcher.")
        let button = NSButton(title: "Open Switcher Settings…", target: self, action: #selector(openSwitcherSettings))
        button.isEnabled = isRunning
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
