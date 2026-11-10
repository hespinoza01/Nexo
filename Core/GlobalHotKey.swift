import Cocoa
import Carbon.HIToolbox
import ShortcutRecorder

/// Global keyboard shortcuts for Nexo modules (the switcher keeps its own registration in
/// `KeyboardEvents`). Uses Carbon `RegisterEventHotKey`: it needs no Accessibility permission and the
/// system routes the press to us even when another app is frontmost.
///
/// Every Carbon hotkey handler of the process sits on the same dispatcher target and is called
/// most-recently-installed first; each one must return `eventNotHandledErr` for hotkeys whose
/// signature isn't its own, or it swallows the press for the others.
final class GlobalHotKey {
    private static let signature: OSType = "nexo".utf16.reduce(0) { ($0 << 8) + OSType($1) }
    private static var nextId: UInt32 = 1
    private static var handlers = [UInt32: () -> Void]()
    private static var eventHandler: EventHandlerRef?

    private let id: UInt32
    private var reference: EventHotKeyRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        id = Self.nextId
        Self.nextId += 1
        self.action = action
    }

    deinit {
        unregister()
    }

    /// Replaces any previous registration. A nil or empty shortcut just unregisters.
    func register(_ shortcut: Shortcut?) {
        unregister()
        guard let shortcut, shortcut.keyCode != .none else { return }
        Self.installHandlerIfNeeded()
        let hotKeyId = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(shortcut.carbonKeyCode, shortcut.carbonModifierFlags, hotKeyId,
            GetEventDispatcherTarget(), UInt32(kEventHotKeyNoOptions), &reference)
        guard status == noErr else {
            NSLog("Nexo: RegisterEventHotKey failed (\(status)) for \(shortcut.readableStringRepresentation(isASCII: true))")
            return
        }
        Self.handlers[id] = action
    }

    func unregister() {
        guard let reference else { return }
        UnregisterEventHotKey(reference)
        self.reference = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyId = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyId)
            guard hotKeyId.signature == GlobalHotKey.signature, let handler = GlobalHotKey.handlers[hotKeyId.id] else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async(execute: handler)
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }
}

/// Persists a `Shortcut` in UserDefaults as its dictionary representation.
enum ShortcutStore {
    static func load(_ key: String) -> Shortcut? {
        guard let dictionary = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        return Shortcut(dictionary: dictionary)
    }

    static func save(_ shortcut: Shortcut?, _ key: String) {
        guard let shortcut else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(shortcut.dictionaryRepresentation, forKey: key)
    }
}

/// Recorder control bound to a `ShortcutStore` key; `onChange` fires with the new value.
final class HotKeyField: RecorderControl {
    private let key: String
    private let onChange: (Shortcut?) -> Void

    init(key: String, onChange: @escaping (Shortcut?) -> Void) {
        self.key = key
        self.onChange = onChange
        super.init(frame: .zero)
        objectValue = ShortcutStore.load(key)
        target = self
        action = #selector(changed)
        widthAnchor.constraint(equalToConstant: 160).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    @objc private func changed() {
        ShortcutStore.save(objectValue, key)
        onChange(objectValue)
    }
}
