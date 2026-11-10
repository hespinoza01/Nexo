import Cocoa

/// Side-effect dispatcher for preference changes. Each branch of `preferenceChanged(_:)`
/// calls into a domain-specific owner (TrackpadEvents, ControlsTab, the switcher UI) rather than
/// implementing the side effect inline. Login item, menubar icon and updates belong to Nexo, not here. Over time each call-site
/// should subscribe directly to its own preference; this file is a transition scaffold.
class PreferencesEvents {
    private static var initialized = false
    private static let preferencesRequiringUiReset = [
        "appearanceStyle",
        "appearanceSize",
        "appearanceTheme",
        "showOnScreen",
    ]

    /// True if `key` is an indexed override of one of the 5 overridable appearance prefs
    /// (e.g. `appearanceStyleOverride2`). Used to trigger a UI reset and override-label refresh
    /// when an override changes, so the switcher and Settings UI both pick up the new value.
    private static func isOverrideKey(_ key: String) -> Bool {
        for baseName in Preferences.appearanceOverrideBaseNames {
            for i in 0...Preferences.maxShortcutCount {
                if Preferences.indexToName(baseName, i) == key { return true }
            }
        }
        return false
    }

    /// True if `key` is an indexed per-shortcut grouping pref (`showAppsOrWindows`, `showTabsAsWindows`
    /// + index suffix). These moved from global to per-shortcut, so a change on any index needs the
    /// same UI reset that the old global key used to trigger.
    private static func isPerShortcutGroupingKey(_ key: String) -> Bool {
        for baseName in ["showAppsOrWindows", "showTabsAsWindows"] {
            for i in 0...Preferences.maxShortcutCount {
                if Preferences.indexToName(baseName, i) == key { return true }
            }
        }
        return false
    }

    static func initialize() {
        guard !initialized else { return }
        initialized = true
        ControlsTab.initializePreferencesDependentState()
        TrackpadEvents.toggle(Preferences.nextWindowGesture != .disabled)
    }

    static func preferenceChanged(_ key: String) {
        guard initialized else { return }
        SearchDiscoveryHint.shared.cancel()
        ControlsTab.preferenceChanged(key)
        switch key {
        case "nextWindowGesture": TrackpadEvents.toggle(Preferences.nextWindowGesture != .disabled)
        case let k where preferencesRequiringUiReset.contains(k): App.resetPreferencesDependentComponents()
        case let k where isOverrideKey(k) || isPerShortcutGroupingKey(k): App.resetPreferencesDependentComponents()
        default: break
        }
    }
}
