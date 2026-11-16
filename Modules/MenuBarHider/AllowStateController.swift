import Foundation

/// Where an app's menu bar icons live. Hiding is per app: macOS keeps one switch per app.
enum MenuBarSection: String, CaseIterable, Codable {
    /// Always drawn.
    case visible
    /// Turned off, shown again on demand (shortcut, menu) for a few seconds.
    case hidden
    /// Turned off until moved back.
    case alwaysHidden
}

/// Drives the native "Allow in the Menu Bar" switches from Nexo's sections.
///
/// The switches are the user's too, so Nexo keeps a journal of the apps it turned off and only ever
/// turns those back on. The journal is written before the list, so a crash between the two leaves
/// nothing hidden for good: the next `apply` or `restoreAll` turns them back on.
final class AllowStateController {
    enum Key {
        static let sections = "menuBar.sections"
        static let journal = "menuBar.disallowed"
    }

    private let store: AllowListStore
    private let defaults: UserDefaults

    init(store: AllowListStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    var sections: [String: MenuBarSection] {
        get { (defaults.dictionary(forKey: Key.sections) as? [String: String] ?? [:]).compactMapValues(MenuBarSection.init) }
        set { defaults.set(newValue.filter { $0.value != .visible }.mapValues(\.rawValue), forKey: Key.sections) }
    }

    /// Apps Nexo turned off and has not turned back on yet.
    private(set) var journal: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.journal) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.journal) }
    }

    func section(of id: String) -> MenuBarSection { sections[id] ?? .visible }

    func states() throws -> [String: Bool] {
        TrackedApplications.allowedStates(in: try store.read())
    }

    func desiredOff(revealed: Bool) -> Set<String> {
        // `system:` keys are macOS's own modules, driven by `SystemSectionController`.
        Set(sections.filter { SystemSectionController.moduleID($0.key) == nil
            && ($0.value == .alwaysHidden || ($0.value == .hidden && !revealed)) }.keys)
    }

    /// Turns off what should be hidden and back on what Nexo hid that no longer should be.
    /// Apps the user turned off in System Settings are left alone. Returns the resulting states.
    @discardableResult
    func apply(revealed: Bool, alsoAllow extra: Set<String> = []) throws -> [String: Bool] {
        let array = try store.read()
        let states = TrackedApplications.allowedStates(in: array)
        let off = desiredOff(revealed: revealed)
        let toDisallow = off.filter { states[$0] == true }
        let toAllow = journal.subtracting(off).union(extra.subtracting(off))
        journal = journal.union(toDisallow)
        let disallowed = TrackedApplications.settingAllowed(false, for: toDisallow, in: array)
        let allowed = TrackedApplications.settingAllowed(true, for: toAllow, in: disallowed.array)
        if !disallowed.changed.isEmpty || !allowed.changed.isEmpty { try store.write(allowed.array) }
        let final = TrackedApplications.allowedStates(in: allowed.array)
        journal = journal.intersection(off).filter { final[$0] == false }
        return final
    }

    /// Moves an app to a section. Moving to Visible an app the user had turned off in System
    /// Settings turns it on: that is an explicit request.
    @discardableResult
    func setSection(_ section: MenuBarSection, for id: String, revealed: Bool) throws -> [String: Bool] {
        var all = sections
        all[id] = section
        sections = all
        return try apply(revealed: revealed, alsoAllow: section == .visible ? [id] : [])
    }

    /// Turns back on every app Nexo turned off and forgets the sections' effect (sections stay).
    func restoreAll() throws {
        let ids = journal
        guard !ids.isEmpty else { return }
        let allowed = TrackedApplications.settingAllowed(true, for: ids, in: try store.read())
        if !allowed.changed.isEmpty { try store.write(allowed.array) }
        journal = []
    }
}
