import Cocoa

final class NexoApp: NSObject, NSApplicationDelegate {
    private let registry = ModuleRegistry.shared
    private var statusItem: StatusItemController?
    private lazy var settingsWindow = SettingsWindowController(registry: registry)

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerModules()
        registry.startEnabledModules()
        statusItem = StatusItemController(registry: registry) { [weak self] moduleId in
            self?.settingsWindow.show(moduleId: moduleId)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry.stopAll()
    }

    /// Clicking the app in Finder/Spotlight while it's already running opens Settings,
    /// since an LSUIElement app has no Dock icon or window to bring forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show(moduleId: nil)
        return false
    }

    /// Each module sub-plan adds its `registry.register(...)` line here.
    private func registerModules() {
    }
}
