import Foundation

/// System-wide gap between menu bar items (`NSStatusItemSpacing`) and the highlight padding around
/// each item (`NSStatusItemSelectionPadding`), stored per host in the global domain. Every app reads
/// them when it starts, so a change shows up as apps relaunch (all of them after logging out).
enum MenuBarSpacing {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"
    static let range = 0...16
    /// macOS default when the keys are absent.
    static let systemDefault = 16

    /// Current value, or nil when macOS uses its default.
    static var current: Int? {
        let value = CFPreferencesCopyValue(spacingKey as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (value as? NSNumber)?.intValue
    }

    /// nil restores the macOS default. The selection padding follows at half the spacing (min 2), so
    /// the highlight never overlaps the neighbour.
    static func set(_ spacing: Int?) {
        let spacingValue = spacing.map { NSNumber(value: min(max($0, range.lowerBound), range.upperBound)) }
        let paddingValue = spacing.map { NSNumber(value: max(2, min(max($0, range.lowerBound), range.upperBound) / 2)) }
        CFPreferencesSetValue(spacingKey as CFString, spacingValue, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSetValue(paddingKey as CFString, paddingValue, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
}
