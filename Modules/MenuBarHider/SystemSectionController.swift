import Foundation

/// Reads and flips one of macOS's own menu bar modules (by `SystemMenuItems.Module.id`).
protocol SystemModuleSwitch {
    func exists(_ id: String) -> Bool
    func isShown(_ id: String) -> Bool
    func setShown(_ shown: Bool, _ id: String)
}

struct LiveSystemModuleSwitch: SystemModuleSwitch {
    func exists(_ id: String) -> Bool { SystemMenuItems.modules.contains { $0.id == id } }

    func isShown(_ id: String) -> Bool {
        SystemMenuItems.modules.first { $0.id == id }.map(SystemMenuItems.isShown) ?? true
    }

    func setShown(_ shown: Bool, _ id: String) {
        guard let module = SystemMenuItems.modules.first(where: { $0.id == id }) else { return }
        SystemMenuItems.setShown(shown, module)
    }
}

/// Puts macOS's own icons in the same Hidden / Always hidden sections as apps' icons.
///
/// Unlike apps, they have a live show/hide flag that needs no Full Disk Access. A module placed in a
/// section is Nexo's to drive; Nexo records the ones it turned off (`menuBar.systemHidden`) so turning
/// the module off shows them again. One the user switched off themselves and never placed is left alone.
final class SystemSectionController {
    static let prefix = "system:"
    static let journalKey = "menuBar.systemHidden"

    private let modules: SystemModuleSwitch
    private let defaults: UserDefaults

    init(modules: SystemModuleSwitch = LiveSystemModuleSwitch(), defaults: UserDefaults = .standard) {
        self.modules = modules
        self.defaults = defaults
    }

    static func key(_ moduleID: String) -> String { prefix + moduleID }

    static func moduleID(_ key: String) -> String? {
        key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }

    /// Modules Nexo turned off and has not turned back on.
    private(set) var journal: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.journalKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.journalKey) }
    }

    /// `sections` is the shared section map; only `system:` keys are read.
    func apply(sections: [String: MenuBarSection], revealed: Bool) {
        // A module id this macOS no longer has is ignored, never journaled.
        let placed = sections.compactMap { key, section in Self.moduleID(key).map { ($0, section) } }.filter { modules.exists($0.0) }
        let managed = Set(placed.filter { $0.1 != .visible }.map(\.0))
        let off = Set(placed.filter { $0.1 == .alwaysHidden || ($0.1 == .hidden && !revealed) }.map(\.0))
        let toHide = off.filter { modules.isShown($0) }
        // Recorded before the change: a crash in between still restores them.
        journal = journal.union(toHide)
        toHide.forEach { modules.setShown(false, $0) }
        // Revealed ones, and ones Nexo hid that left every hidden section.
        for id in managed.subtracting(off).union(journal.subtracting(managed)) where !modules.isShown(id) {
            modules.setShown(true, id)
        }
        journal = journal.intersection(managed)
    }

    /// Shows every module Nexo hid.
    func restoreAll() {
        journal.filter { !modules.isShown($0) }.forEach { modules.setShown(true, $0) }
        journal = []
    }
}
