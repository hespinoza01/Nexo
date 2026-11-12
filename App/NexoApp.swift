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

    static func setStatusIndicator(_ symbol: String?, owner: String) {
        statusItem?.setIndicator(symbol, owner: owner)
    }

    /// True once Nexo is quitting (including logout, restart and shutdown): modules stopping now
    /// are not being turned off by the user.
    private(set) static var isTerminating = false

    static func terminate() {
        isTerminating = true
        registry.stopAll()
    }

    /// Nexo's settings window, where embedded module UIs attach their sheets and alerts.
    static var settingsHostWindow: NSWindow? { settingsWindow?.window }

    static func showSettings(moduleId: String?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(registry: registry) }
        settingsWindow?.show(moduleId: moduleId)
    }

    /// Each module sub-plan adds its `registry.register(...)` line here.
    private static func registerModules() {
        registry.register(SwitcherModule())
        registry.register(KeepAwakeModule())
        registry.register(InputSourceModule())
        registry.register(MonitorModule())
        registry.register(SimulatorsModule())
        registry.register(SnappingModule())
        registry.register(ClipboardModule())
        registry.register(PortsModule())
        registry.register(QuitProtectionModule())
        registry.register(AudioMixerModule())
        registry.register(MenuBarModule())
    }
}
