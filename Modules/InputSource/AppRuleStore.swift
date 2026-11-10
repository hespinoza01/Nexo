import Foundation

/// Per-app input source rules (bundle id → input source id), plus an optional default applied to
/// apps without a rule. Persisted in UserDefaults.
final class AppRuleStore {
    private enum Key {
        static let rules = "inputSource.rules"
        static let fallback = "inputSource.default"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var rules: [String: String] {
        get { defaults.dictionary(forKey: Key.rules) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.rules) }
    }

    var fallbackSourceId: String? {
        get { defaults.string(forKey: Key.fallback) }
        set { defaults.set(newValue, forKey: Key.fallback) }
    }

    func setRule(_ sourceId: String?, for bundleId: String) {
        var current = rules
        current[bundleId] = sourceId
        rules = current
    }

    /// The source to switch to when `bundleId` becomes active, or nil to leave the current one.
    func sourceId(for bundleId: String?) -> String? {
        guard let bundleId else { return fallbackSourceId }
        return rules[bundleId] ?? fallbackSourceId
    }
}
