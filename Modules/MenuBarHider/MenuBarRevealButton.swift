import Cocoa
import Combine

/// Nexo's own menu bar button for hidden icons: click shows them for a few seconds (click again to
/// hide), right-click or ⌥-click opens a small menu. Its arrow points the way icons appear.
final class MenuBarRevealButton: NSObject {
    static let enabledKey = "menuBar.revealButton"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let manager: MenuBarManager
    private var statusItem: NSStatusItem?
    private var observation: AnyCancellable?

    init(manager: MenuBarManager) {
        self.manager = manager
    }

    func install() {
        guard statusItem == nil, Self.isEnabled else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "NexoReveal"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        observation = manager.$revealedUntil.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    func remove() {
        observation = nil
        statusItem.map(NSStatusBar.system.removeStatusItem)
        statusItem = nil
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let revealed = manager.isRevealed
        let image = NSImage(systemSymbolName: revealed ? "chevron.right.circle.fill" : "chevron.left.circle",
            accessibilityDescription: revealed ? L("Hide again") : L("Show hidden icons"))
        image?.isTemplate = true
        button.image = image
        button.toolTip = revealed ? L("Hide again") : L("Show hidden icons")
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        guard event?.type != .rightMouseUp, event?.modifierFlags.contains(.option) != true else { return showMenu() }
        guard manager.controller.sections.values.contains(.hidden) else {
            return NexoCore.showSettings(moduleId: MenuBarModule.id)
        }
        manager.toggleReveal()
    }

    private func showMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: manager.isRevealed ? L("Hide again") : L("Show hidden icons"), action: #selector(toggleReveal), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = manager.controller.sections.values.contains(.hidden)
        let settings = NSMenuItem(title: L("Menu Bar Settings…"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.items = [toggle, .separator(), settings]
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleReveal() { manager.toggleReveal() }

    @objc private func openSettings() { NexoCore.showSettings(moduleId: MenuBarModule.id) }
}
