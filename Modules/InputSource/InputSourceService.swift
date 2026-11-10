import Carbon
import Foundation

struct InputSource: Equatable {
    let id: String
    let name: String
}

/// Text Input Sources (keyboard layouts and input methods) via Carbon TIS.
/// Only selectable keyboard sources are listed, matching the menu bar Input menu.
enum InputSourceService {
    static func selectable() -> [InputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as [String: Any] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap(source)
    }

    static func current() -> InputSource? {
        guard let tis = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return source(tis)
    }

    @discardableResult
    static func select(_ id: String) -> Bool {
        guard current()?.id != id else { return true }
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let tis = list.first else { return false }
        return TISSelectInputSource(tis) == noErr
    }

    private static func source(_ tis: TISInputSource) -> InputSource? {
        guard let id = string(tis, kTISPropertyInputSourceID) else { return nil }
        return InputSource(id: id, name: string(tis, kTISPropertyLocalizedName) ?? id)
    }

    private static func string(_ tis: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(tis, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
