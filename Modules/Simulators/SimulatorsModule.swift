import Cocoa

/// Launch iOS simulators and Android emulators from the menu bar (inspired by MiniSim, MIT).
/// Device lists come from external tools that take hundreds of ms, so they are refreshed in the
/// background and the menu shows the last known list.
final class SimulatorsModule: NexoModule {
    static let id = "simulators"
    var title: String { L("Simulators") }
    let icon = "iphone"
    private(set) var isRunning = false

    private enum Key {
        static let hiddenRuntimes = "simulators.hiddenRuntimes"
        static let showAndroid = "simulators.showAndroid"
    }

    private var devices = [SimulatorDevice]()
    private var refreshing = false

    private var hiddenRuntimes: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.hiddenRuntimes) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Key.hiddenRuntimes) }
    }

    private var showAndroid: Bool {
        get { UserDefaults.standard.object(forKey: Key.showAndroid) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.showAndroid) }
    }

    func start() {
        isRunning = true
        refresh()
    }

    func stop() {
        isRunning = false
    }

    func menuItems() -> [NSMenuItem] {
        refresh()
        let visible = devices.filter { !hiddenRuntimes.contains($0.runtime) && ($0.platform == .ios || showAndroid) }
        guard !visible.isEmpty else {
            let empty = NSMenuItem(title: devices.isEmpty ? L("Loading devices…") : L("No devices"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return [empty]
        }
        let booted = visible.filter(\.isBooted)
        var items = booted.map(deviceItem)
        let groups = Dictionary(grouping: visible.filter { !$0.isBooted }, by: \.runtime)
        for runtime in groups.keys.sorted(by: >) {
            let item = NSMenuItem(title: runtime, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: runtime == "Android" ? "smartphone" : "iphone", accessibilityDescription: nil)
            let submenu = NSMenu()
            groups[runtime]?.forEach { submenu.addItem(deviceItem($0)) }
            item.submenu = submenu
            items.append(item)
        }
        return items
    }

    func settingsView() -> NSView {
        let sdk = NSTextField(string: UserDefaults.standard.string(forKey: AndroidDeviceService.sdkPathKey) ?? "")
        sdk.placeholderString = AndroidDeviceService.sdkPath
        sdk.widthAnchor.constraint(equalToConstant: 320).isActive = true
        sdk.target = self
        sdk.action = #selector(sdkChanged(_:))
        let android = NSButton(checkboxWithTitle: L("Show Android emulators"), target: self, action: #selector(androidToggled(_:)))
        android.state = showAndroid ? .on : .off
        let runtimes = Set(devices.map(\.runtime)).sorted(by: >).map { runtime -> NSButton in
            let box = NSButton(checkboxWithTitle: runtime, target: self, action: #selector(runtimeToggled(_:)))
            box.identifier = .init(runtime)
            box.state = hiddenRuntimes.contains(runtime) ? .off : .on
            return box
        }
        return SettingsForm.stack([
            android,
            SettingsForm.row("Android SDK", sdk),
            SettingsForm.note(AndroidDeviceService.isAvailable ? L("Emulator found.") : L("Emulator not found at %@/emulator.", AndroidDeviceService.sdkPath)),
            SettingsForm.header(L("Runtimes shown")),
            SettingsForm.stack(runtimes.isEmpty ? [SettingsForm.note(L("Open the menu once to load devices."))] : runtimes, spacing: 4),
        ])
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let includeAndroid = showAndroid
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = IOSDeviceService.devices() + (includeAndroid ? AndroidDeviceService.devices() : [])
            DispatchQueue.main.async {
                self?.devices = found
                self?.refreshing = false
            }
        }
    }

    private func deviceItem(_ device: SimulatorDevice) -> NSMenuItem {
        let title = device.isBooted ? L("%@ — running", device.name) : device.name
        let item = NSMenuItem(title: title, action: #selector(deviceClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = device.id
        item.state = device.isBooted ? .on : .off
        item.toolTip = device.isBooted ? L("Click to shut down") : L("Click to boot")
        return item
    }

    @objc private func deviceClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let device = devices.first(where: { $0.id == id }) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch (device.platform, device.isBooted) {
            case (.ios, false): IOSDeviceService.boot(device)
            case (.ios, true): IOSDeviceService.shutdown(device)
            case (.android, false): AndroidDeviceService.boot(device)
            case (.android, true): AndroidDeviceService.shutdown(device)
            }
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func sdkChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(sender.stringValue.trimmingCharacters(in: .whitespaces), forKey: AndroidDeviceService.sdkPathKey)
        refresh()
    }

    @objc private func androidToggled(_ sender: NSButton) {
        showAndroid = sender.state == .on
        refresh()
    }

    @objc private func runtimeToggled(_ sender: NSButton) {
        guard let runtime = sender.identifier?.rawValue else { return }
        var hidden = hiddenRuntimes
        if sender.state == .on { hidden.remove(runtime) } else { hidden.insert(runtime) }
        hiddenRuntimes = hidden
    }
}
