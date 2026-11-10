import Cocoa

/// macOS privacy permissions a module may need. `PermissionCenter` checks and requests them.
enum ModulePermission: String, CaseIterable, Codable {
    case accessibility
    case screenRecording
    case automation
    case audioCapture

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        case .audioCapture: return "System Audio Recording"
        }
    }
}

/// A self-contained feature of Nexo (window switcher, keep awake, monitor, …).
/// The registry instantiates every module at launch but only calls `start()` on enabled ones,
/// so `init` must stay cheap: no observers, taps or timers before `start()`.
protocol NexoModule: AnyObject {
    /// Stable identifier; used as the UserDefaults key suffix. Never rename once shipped.
    static var id: String { get }
    var title: String { get }
    /// SF Symbol name for the settings sidebar and menu section header.
    var icon: String { get }
    var permissions: [ModulePermission] { get }
    var enabledByDefault: Bool { get }
    var isRunning: Bool { get }
    func start()
    func stop()
    /// Items shown under this module's section in the shared status menu. Called each time the menu opens.
    func menuItems() -> [NSMenuItem]
    /// Content of this module's page in the settings window.
    func settingsView() -> NSView
}

extension NexoModule {
    var id: String { Self.id }
    var enabledByDefault: Bool { true }
    var permissions: [ModulePermission] { [] }
    func menuItems() -> [NSMenuItem] { [] }
}
