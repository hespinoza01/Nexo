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

    private func configureButton() {
        let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Nexo")
        image?.isTemplate = true
        statusItem.button?.image = image
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
        menu.addItem(actionItem("Settings…", #selector(openSettingsAction), ","))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Nexo", #selector(quitAction), "q"))
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
