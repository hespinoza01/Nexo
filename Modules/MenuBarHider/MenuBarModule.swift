import Cocoa

/// Menu bar housekeeping on macOS 27, where Ice-style hiding no longer works (see
/// Spikes/MenuBarHide/FINDINGS.md): the bar is drawn as a single window by MenuBarAgent and hiding
/// third-party items now needs a private "assessment mode" assertion that also blocks clicks on the
/// clock, battery and Wi-Fi. Instead this module controls Nexo's own extra items and opens the native
/// per-app "Allow in the Menu Bar" list, which hides third-party items in a supported way.
final class MenuBarModule: NexoModule {
    static let id = "menuBar"
    let title = "Menu Bar"
    let icon = "menubar.rectangle"
    private(set) var isRunning = false

    /// Nexo modules that add their own status item, besides the main Nexo icon.
    private static let itemOwners = [MonitorModule.id]
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    func start() { isRunning = true }

    func stop() { isRunning = false }

    func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Hide Menu Bar Icons…", action: #selector(openSystemSettings), keyEquivalent: "")
        item.target = self
        return [item]
    }

    func settingsView() -> NSView {
        let registry = NexoCore.registry
        let toggles = Self.itemOwners.compactMap { registry.module(withId: $0) }.map { module -> NSButton in
            let box = NSButton(checkboxWithTitle: "Show \(module.title) in the menu bar", target: self, action: #selector(ownerToggled(_:)))
            box.identifier = .init(module.id)
            box.state = registry.isEnabled(module) ? .on : .off
            return box
        }
        let open = NSButton(title: "Open “Allow in the Menu Bar”…", target: self, action: #selector(openSystemSettings))
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SettingsForm.stack([
            SettingsForm.header("Nexo items"),
            SettingsForm.stack(toggles, spacing: 6),
            SettingsForm.header("Other apps"),
            open,
            SettingsForm.note("macOS \(version.majorVersion).\(version.minorVersion) lets you turn each app's menu bar icon on or off in System Settings › Menu Bar."),
            SettingsForm.note(version.majorVersion >= 27
                ? "Why no Ice/Bartender-style hidden section: since macOS 27 the menu bar is drawn as one window, so moving or collapsing items no longer hides them. The only remaining way is a private Apple API that makes the clock, battery and Wi-Fi ignore clicks while items are hidden."
                : "On this macOS version a separator-based hider (Ice) also works alongside Nexo."),
        ])
    }

    @objc private func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    @objc private func ownerToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let module = NexoCore.registry.module(withId: id) else { return }
        NexoCore.registry.setEnabled(sender.state == .on, for: module)
    }
}
