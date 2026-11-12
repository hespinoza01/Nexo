import Cocoa

/// Menu bar housekeeping on macOS 27, where Ice-style hiding no longer works (see
/// Spikes/MenuBarHide/FINDINGS.md): the bar is drawn as a single window by MenuBarAgent and hiding
/// third-party items now needs a private "assessment mode" assertion that also blocks clicks on the
/// clock, battery and Wi-Fi. Instead this module controls Nexo's own extra items and opens the native
/// per-app "Allow in the Menu Bar" list, which hides third-party items in a supported way.
final class MenuBarModule: NexoModule {
    static let id = "menuBar"
    var title: String { L("Menu Bar") }
    let icon = "menubar.rectangle"
    private(set) var isRunning = false

    /// Nexo modules that add their own status item, besides the main Nexo icon.
    private static let itemOwners = [MonitorModule.id]
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    func start() { isRunning = true }

    func stop() { isRunning = false }

    func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: L("Hide Menu Bar Icons…"), action: #selector(openSystemSettings), keyEquivalent: "")
        item.target = self
        return [item]
    }

    func settingsView() -> NSView {
        let registry = NexoCore.registry
        let toggles = Self.itemOwners.compactMap { registry.module(withId: $0) }.map { module -> NSButton in
            let box = NSButton(checkboxWithTitle: L("Show %@ in the menu bar", module.title), target: self, action: #selector(ownerToggled(_:)))
            box.identifier = .init(module.id)
            box.state = registry.isEnabled(module) ? .on : .off
            return box
        }
        let open = NSButton(title: L("Open “Allow in the Menu Bar”…"), target: self, action: #selector(openSystemSettings))
        let spacing = NSSlider(value: Double(MenuBarSpacing.current ?? MenuBarSpacing.systemDefault),
            minValue: Double(MenuBarSpacing.range.lowerBound), maxValue: Double(MenuBarSpacing.range.upperBound),
            target: self, action: #selector(spacingChanged(_:)))
        spacing.numberOfTickMarks = MenuBarSpacing.range.count
        spacing.allowsTickMarkValuesOnly = true
        spacing.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let value = NSTextField(labelWithString: "")
        spacingLabel = value
        refreshSpacingLabel()
        let reset = NSButton(title: L("Use macOS default"), target: self, action: #selector(resetSpacing))
        let restart = NSButton(title: L("Restart Nexo to apply"), target: self, action: #selector(restartNexo))
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SettingsForm.stack([
            SettingsForm.header(L("Nexo items")),
            SettingsForm.stack(toggles, spacing: 6),
            SettingsForm.header(L("Spacing between icons")),
            SettingsForm.row(L("Spacing"), NSStackView(views: [spacing, value])),
            NSStackView(views: [reset, restart]),
            SettingsForm.note(L("Applies to the whole menu bar. Each app picks it up when it relaunches; log out and back in to apply it to all of them.")),
            SettingsForm.header(L("Other apps")),
            open,
            SettingsForm.note(L("macOS %d.%d lets you turn each app's menu bar icon on or off in System Settings › Menu Bar.", version.majorVersion, version.minorVersion)),
            SettingsForm.note(version.majorVersion >= 27
                ? L("Why there is no hidden section: since macOS 27 the menu bar is drawn as one window, so moving or collapsing items no longer hides them. The only remaining way is a private Apple API that makes the clock, battery and Wi-Fi ignore clicks while items are hidden.")
                : L("On this macOS version a separator-based hider from another app also works alongside Nexo.")),
        ])
    }

    private weak var spacingLabel: NSTextField?

    private func refreshSpacingLabel() {
        spacingLabel?.stringValue = MenuBarSpacing.current.map { L("%d pt", $0) } ?? L("Default (%d pt)", MenuBarSpacing.systemDefault)
    }

    @objc private func spacingChanged(_ sender: NSSlider) {
        MenuBarSpacing.set(Int(sender.doubleValue.rounded()))
        refreshSpacingLabel()
    }

    @objc private func resetSpacing() {
        MenuBarSpacing.set(nil)
        refreshSpacingLabel()
    }

    @objc private func restartNexo() {
        App.restart()
    }

    @objc private func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    @objc private func ownerToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let module = NexoCore.registry.module(withId: id) else { return }
        NexoCore.registry.setEnabled(sender.state == .on, for: module)
    }
}
