import Foundation

/// MenuBarAgent's per-app "Allow in the Menu Bar" list on macOS 27.
///
/// Stored as the `trackedApplications` preference of the `group.com.apple.controlcenter` group
/// container: data holding a binary property list, a flat array alternating key, value, key, value
/// (measured on macOS 27.0.1). A key is `{"bundle": {"_0": "<bundle id>"}}` (or an `adhocBinary` key
/// for unsigned binaries); a value is `{"location", "menuItemLocations", "isAllowed"}`.
/// Only `isAllowed` under bundle keys is ever changed; everything else is passed back untouched.
/// Adapted from Ice's TrackedApplications27 (GPL-3.0).
enum TrackedApplications {
    struct Entry: Equatable {
        let bundleID: String?
        let isAllowed: Bool?
        let valueIndex: Int
    }

    static func entries(in array: [Any]) -> [Entry] {
        stride(from: 0, to: array.count - 1, by: 2).map { keyIndex in
            let value = array[keyIndex + 1] as? [String: Any]
            return Entry(bundleID: bundleID(ofKey: array[keyIndex]), isAllowed: value?["isAllowed"] as? Bool, valueIndex: keyIndex + 1)
        }
    }

    static func bundleID(ofKey key: Any) -> String? {
        guard let key = key as? [String: Any], key.count == 1, let bundle = key["bundle"] as? [String: Any] else { return nil }
        return bundle["_0"] as? String
    }

    /// `isAllowed` per bundle; a bundle listed twice counts as allowed if either entry is.
    static func allowedStates(in array: [Any]) -> [String: Bool] {
        var states = [String: Bool]()
        for entry in entries(in: array) {
            guard let id = entry.bundleID, let allowed = entry.isAllowed else { continue }
            states[id] = (states[id] ?? false) || allowed
        }
        return states
    }

    /// The array with `isAllowed` set for the given bundles, and the bundles actually changed.
    static func settingAllowed(_ allowed: Bool, for ids: Set<String>, in array: [Any]) -> (array: [Any], changed: Set<String>) {
        guard !ids.isEmpty else { return (array, []) }
        var result = array
        var changed = Set<String>()
        for entry in entries(in: array) {
            guard let id = entry.bundleID, ids.contains(id), let current = entry.isAllowed, current != allowed,
                  var value = array[entry.valueIndex] as? [String: Any] else { continue }
            value["isAllowed"] = allowed
            result[entry.valueIndex] = value
            changed.insert(id)
        }
        return (result, changed)
    }

    static func decode(_ data: Data) -> [Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
    }

    static func encode(_ array: [Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: array, format: .binary, options: 0)
    }
}
