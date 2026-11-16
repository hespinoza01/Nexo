import Cocoa
import SwiftUI

/// Menu bar manager for macOS 27, where the bar is a single MenuBarAgent window and separator-based
/// hiding no longer works (Spikes/MenuBarHide/FINDINGS.md). Apps' icons are hidden through macOS's own
/// per-app "Allow in the Menu Bar" switch (`AllowStateController`), and reordered with a synthetic
/// ⌘-drag (`MenuBarDragger`). Also controls Nexo's own extra items and the icon spacing.
final class MenuBarModule: NexoModule {
    static let id = "menuBar"
    var title: String { L("Menu Bar") }
    let icon = "menubar.rectangle"
    private(set) var isRunning = false
    let permissions: [ModulePermission] = [.accessibility, .fullDiskAccess]
    let manager = MenuBarManager()
    private lazy var revealButton = MenuBarRevealButton(manager: manager)
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.manager.toggleReveal() }

    /// Nexo modules that add their own status item, besides the main Nexo icon.
    private static let itemOwners = [MonitorModule.id]
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    func start() {
        isRunning = true
        manager.start()
        hotKey.register(ShortcutStore.load(MenuBarManager.Key.revealShortcut))
        revealButton.install()
    }

    /// Turning the module off shows every icon Nexo hid; quitting Nexo keeps them hidden.
    func stop() {
        isRunning = false
        hotKey.unregister()
        revealButton.remove()
        manager.stop(restore: !NexoCore.isTerminating)
    }

    func menuItems() -> [NSMenuItem] {
        guard manager.controller.sections.values.contains(.hidden) else { return [] }
        let remaining = manager.revealedUntil.map { Int(ceil($0.timeIntervalSinceNow)) } ?? 0
        let title = manager.isRevealed ? L("Hide icons again (%d s)", remaining) : L("Show hidden icons")
        let item = NSMenuItem(title: title, action: #selector(toggleReveal), keyEquivalent: "")
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
        let layout = NSHostingView(rootView: MenuBarLayoutView(manager: manager))
        layout.translatesAutoresizingMaskIntoConstraints = false
        layout.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        let shortcut = HotKeyField(key: MenuBarManager.Key.revealShortcut) { [weak self] in
            guard self?.isRunning == true else { return }
            self?.hotKey.register($0)
        }
        shortcut.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let form = SettingsForm.stack([
            SettingsForm.header(L("Icons of other apps")),
            SettingsForm.row(L("Show hidden icons"), shortcut),
            revealButtonToggle(),
            layout,
            SettingsForm.note(L("Hiding works per app: macOS has one “Allow in the Menu Bar” switch per app, so all of an app's icons go together. Turning this module off shows again every icon Nexo hid.")),
            SettingsForm.header(L("Nexo items")),
            SettingsForm.stack(toggles, spacing: 6),
            SettingsForm.header(L("Spacing between icons")),
            SettingsForm.row(L("Spacing"), NSStackView(views: [spacing, value])),
            NSStackView(views: [reset, restart]),
            SettingsForm.note(L("Applies to the whole menu bar. Each app picks it up when it relaunches; log out and back in to apply it to all of them.")),
            open,
        ])
        layout.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        return form
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

    private func revealButtonToggle() -> NSButton {
        let box = NSButton(checkboxWithTitle: L("Button in the menu bar to show hidden icons"), target: self, action: #selector(revealButtonToggled(_:)))
        box.state = MenuBarRevealButton.isEnabled ? .on : .off
        return box
    }

    @objc private func revealButtonToggled(_ sender: NSButton) {
        MenuBarRevealButton.isEnabled = sender.state == .on
        guard isRunning else { return }
        sender.state == .on ? revealButton.install() : revealButton.remove()
    }

    @objc private func toggleReveal() {
        manager.toggleReveal()
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
