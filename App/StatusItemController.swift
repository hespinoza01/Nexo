import Cocoa

/// The single Nexo status item. Its menu is rebuilt on open from the enabled modules' sections.
final class StatusItemController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let registry: ModuleRegistry
    private let openSettings: (String?) -> Void

    init(registry: ModuleRegistry, openSettings: @escaping (String?) -> Void) {
        self.registry = registry
        self.openSettings = openSettings
        super.init()
        configureButton()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addModuleSections()
        addFooter()
    }

    /// Modules that want to signal a state on the icon (e.g. keep awake active) register an indicator
    /// symbol; the most recently set one wins, and the default icon returns when none is left.
    private var indicators = [(owner: String, symbol: String)]()

    func setIndicator(_ symbol: String?, owner: String) {
        indicators.removeAll { $0.owner == owner }
        if let symbol { indicators.append((owner, symbol)) }
        configureButton()
    }

    private func configureButton() {
        // Always Nexo's "N" mark; an active state (e.g. keep awake on) adds a small dot instead of
        // replacing the icon.
        let image = indicators.isEmpty ? NSImage(named: "MenuBarIcon") : Self.badgedIcon()
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// The N with a dot in its bottom-right corner, cut out from the letter so it stays legible.
    private static func badgedIcon() -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon") else { return nil }
        let size = base.size
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let dot = NSRect(x: size.width - 7, y: 0, width: 7, height: 7)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }

    private func addModuleSections() {
        for module in registry.enabledModules {
            let items = module.menuItems()
            guard !items.isEmpty else { continue }
            menu.addItem(sectionHeader(module))
            items.forEach { menu.addItem($0) }
            menu.addItem(.separator())
        }
    }

    private func sectionHeader(_ module: NexoModule) -> NSMenuItem {
        let item = NSMenuItem.sectionHeader(title: module.title)
        item.image = NSImage(systemSymbolName: module.icon, accessibilityDescription: nil)
        return item
    }

    private func addFooter() {
        menu.addItem(actionItem(L("Settings…"), #selector(openSettingsAction), ","))
        menu.addItem(.separator())
        menu.addItem(actionItem(L("Quit Nexo"), #selector(quitAction), "q"))
    }

    private func actionItem(_ title: String, _ selector: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettingsAction() {
        openSettings(nil)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
