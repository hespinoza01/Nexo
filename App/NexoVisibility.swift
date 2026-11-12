import Cocoa

/// Where Nexo itself shows up besides the menu bar. Off by default: a menu bar utility stays out of
/// the Dock, Dock recents, ⌘Tab and Nexo's own window switcher.
enum NexoVisibility {
    private enum Key {
        static let dock = "general.showInDock"
        static let switcher = "general.showInSwitcher"
    }

    /// Dock icon, Dock recents and ⌘Tab all follow the activation policy.
    static var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: Key.dock) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.dock)
            applyActivationPolicy()
        }
    }

    /// Whether Nexo's own windows (Settings) are listed by the window switcher.
    static var showInSwitcher: Bool {
        get { UserDefaults.standard.bool(forKey: Key.switcher) }
        set { UserDefaults.standard.set(newValue, forKey: Key.switcher) }
    }

    static func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

/// "Visibility" block for the General pane.
final class VisibilityOptions: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let dock = NSButton(checkboxWithTitle: L("Show Nexo in the Dock, recent apps and ⌘Tab"), target: self, action: #selector(dockChanged(_:)))
        dock.state = NexoVisibility.showInDock ? .on : .off
        let switcher = NSButton(checkboxWithTitle: L("Show Nexo's windows in the window switcher"), target: self, action: #selector(switcherChanged(_:)))
        switcher.state = NexoVisibility.showInSwitcher ? .on : .off
        let title = NSTextField(labelWithString: L("Visibility"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let note = NSTextField(wrappingLabelWithString: L("The window switcher change applies after restarting Nexo. macOS keeps its own “Recent Items” list in the Apple menu; set how many it remembers (or 0) in System Settings › Desktop & Dock."))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 520
        [title, dock, switcher, note].forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    @objc private func dockChanged(_ sender: NSButton) {
        NexoVisibility.showInDock = sender.state == .on
        // Switching to accessory hides the windows of an inactive app; keep Settings in front.
        sender.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func switcherChanged(_ sender: NSButton) {
        NexoVisibility.showInSwitcher = sender.state == .on
    }
}
