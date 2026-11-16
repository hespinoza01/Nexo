import Foundation

/// Show/hide switches for macOS's own menu bar modules (Wi-Fi, Bluetooth, Sound…), the same ones as
/// System Settings › Control Center.
///
/// Stored per host in `com.apple.controlcenter` as a bit set per module: 2 = shown in the menu bar,
/// 8 = hidden; other bits (16 = also in Control Center, 1) are kept. Control Center observes the
/// domain through cfprefsd and applies a change within a second, no restart (measured on 27.2 with
/// Bluetooth and Wi-Fi). An absent key means the module's default.
enum SystemMenuItems {
    struct Module: Identifiable, Hashable {
        let id: String
        let title: String
        let shownByDefault: Bool
    }

    private static let domain = "com.apple.controlcenter" as CFString
    /// The input source menu is not a Control Center module: it has its own `visible` flag in
    /// `com.apple.TextInputMenu` (System Settings › Keyboard › Input Sources), applied live (measured on 27.2).
    static let inputMenuID = "InputMenu"
    static let inputMenuOwner = "com.apple.TextInputMenuAgent"
    private static let inputDomain = "com.apple.TextInputMenu" as CFString
    private static let shownBit = 2
    private static let hiddenBit = 8

    static var modules: [Module] {
        [(inputMenuID, L("Input Menu"), true), ("WiFi", L("Wi-Fi"), true), ("Bluetooth", L("Bluetooth"), false), ("Sound", L("Sound"), false),
         ("NowPlaying", L("Now Playing"), true), ("FocusModes", L("Focus"), false), ("Display", L("Display"), false),
         ("ScreenMirroring", L("Screen Mirroring"), false), ("Battery", L("Battery"), true),
         ("KeyboardBrightness", L("Keyboard Brightness"), false), ("AirDrop", L("AirDrop"), false),
         ("StageManager", L("Stage Manager"), false), ("AccessibilityShortcuts", L("Accessibility Shortcuts"), false),
         ("Hearing", L("Hearing"), false), ("MusicRecognition", L("Music Recognition"), false),
         ("Spotlight", L("Spotlight"), false), ("Siri", L("Siri"), false), ("TimeMachine", L("Time Machine"), false),
         ("UserSwitcher", L("Fast User Switching"), false), ("VPN", L("VPN"), false),
         ("VoiceControl", L("Voice Control"), false), ("Weather", L("Weather"), false)]
            .map { Module(id: $0.0, title: $0.1, shownByDefault: $0.2) }
    }

    /// The module behind a menu bar icon's `com.apple.menuextra.<name>` (`now-playing` → NowPlaying).
    static func module(forExtra extra: String) -> Module? {
        let aliases = ["volume": "Sound", "focusmode": "FocusModes", "focus": "FocusModes", "user": "UserSwitcher",
                       "fastuserswitching": "UserSwitcher", "accessibility": "AccessibilityShortcuts", "screenmirror": "ScreenMirroring"]
        let key = extra.lowercased().filter { $0.isLetter || $0.isNumber }
        let id = aliases[key] ?? key
        return modules.first { $0.id.lowercased() == id.lowercased() }
    }

    /// The switchable module behind a system icon, if macOS lets it be hidden.
    static func module(for item: MenuBarItem) -> Module? {
        if item.bundleID == inputMenuOwner { return modules.first { $0.id == inputMenuID } }
        return item.systemExtra.flatMap(module(forExtra:))
    }

    static func symbol(for id: String) -> String {
        let symbols = ["InputMenu": "keyboard", "WiFi": "wifi", "Bluetooth": "dot.radiowaves.left.and.right", "Sound": "speaker.wave.2",
            "NowPlaying": "play.circle", "FocusModes": "moon", "Display": "sun.max", "ScreenMirroring": "rectangle.on.rectangle",
            "Battery": "battery.75percent", "KeyboardBrightness": "light.max", "AirDrop": "dot.radiowaves.up.forward",
            "StageManager": "square.stack.3d.down.right", "AccessibilityShortcuts": "accessibility", "Hearing": "ear",
            "MusicRecognition": "shazam.logo", "Spotlight": "magnifyingglass", "Siri": "waveform", "TimeMachine": "clock.arrow.circlepath",
            "UserSwitcher": "person.crop.circle", "VPN": "network.badge.shield.half.filled", "VoiceControl": "mic",
            "Weather": "cloud.sun", "clock": "clock", "controlcenter": "switch.2", "audiovideo": "video.circle"]
        return symbols[id] ?? "gearshape"
    }

    /// Names for system icons that cannot be switched off.
    static func fixedTitle(forExtra extra: String) -> String? {
        switch extra {
        case "clock": return L("Clock")
        case "controlcenter": return L("Control Center")
        case "audiovideo", "privacy": return L("Privacy indicator")
        default: return nil
        }
    }

    static func isShown(_ module: Module) -> Bool {
        if module.id == inputMenuID {
            return CFPreferencesCopyValue("visible" as CFString, inputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool ?? true
        }
        guard let value = rawValue(module.id) else { return module.shownByDefault }
        return isShown(value: value, default: module.shownByDefault)
    }

    static func setShown(_ shown: Bool, _ module: Module) {
        if module.id == inputMenuID {
            CFPreferencesSetValue("visible" as CFString, shown as CFBoolean, inputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(inputDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            DistributedNotificationCenter.default().postNotificationName(.init("com.apple.TextInputMenu.visibilityChanged"),
                object: nil, deliverImmediately: true)
            return
        }
        let value = updated(rawValue(module.id), shown: shown)
        CFPreferencesSetValue(module.id as CFString, value as CFNumber, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    static func isShown(value: Int, default shownByDefault: Bool) -> Bool {
        if value & hiddenBit != 0 { return false }
        if value & shownBit != 0 { return true }
        return shownByDefault
    }

    static func updated(_ value: Int?, shown: Bool) -> Int {
        ((value ?? 0) & ~(shownBit | hiddenBit)) | (shown ? shownBit : hiddenBit)
    }

    private static func rawValue(_ key: String) -> Int? {
        CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
    }
}
