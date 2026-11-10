import Cocoa

/// Nexo's own bootstrap. `App` (the AltTab-derived NSApplication subclass and delegate) calls into this
/// from its lifecycle callbacks, so the switcher keeps the launch order it was tuned for.
enum NexoCore {
    static let registry = ModuleRegistry.shared
    private static var statusItem: StatusItemController?
    private static var settingsWindow: SettingsWindowController?

    static func launch() {
        // Status item first: module launches (the switcher's onboarding) anchor popovers to it.
        statusItem = StatusItemController(registry: registry) { showSettings(moduleId: $0) }
        registerModules()
        registry.startEnabledModules()
    }

    /// The one Nexo status item; the switcher anchors its onboarding popover to it.
    static var nsStatusItem: NSStatusItem? { statusItem?.statusItem }

    static func terminate() {
        registry.stopAll()
    }

    static func showSettings(moduleId: String?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(registry: registry) }
        settingsWindow?.show(moduleId: moduleId)
    }

    /// Each module sub-plan adds its `registry.register(...)` line here.
    private static func registerModules() {
        registry.register(SwitcherModule())
    }
}
