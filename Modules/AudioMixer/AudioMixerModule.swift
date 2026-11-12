import Cocoa
import CoreAudio

/// Per-app volume (0–150 %) from the menu bar. An app at 100 % has no tap at all, so the mixer costs
/// nothing until a slider moves. Gains persist per bundle id and are re-applied when the app plays
/// again or the default output device changes.
final class AudioMixerModule: NexoModule {
    static let id = "audioMixer"
    var title: String { L("Audio Mixer") }
    let icon = "speaker.wave.2"
    let permissions: [ModulePermission] = [.audioCapture]
    private(set) var isRunning = false

    private static let gainsKey = "audioMixer.gains"
    private var taps = [String: AppAudioTap]()
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private var gains: [String: Float] {
        get { (UserDefaults.standard.dictionary(forKey: Self.gainsKey) as? [String: Double])?.mapValues(Float.init) ?? [:] }
        set { UserDefaults.standard.set(newValue.mapValues(Double.init), forKey: Self.gainsKey) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installListeners()
        reconcile()
    }

    func stop() {
        isRunning = false
        removeListeners()
        taps.values.forEach { $0.stop() }
        taps.removeAll()
    }

    func menuItems() -> [NSMenuItem] {
        var items = [NSMenuItem]()
        if let volume = AudioSystem.outputVolume, let device = AudioSystem.defaultOutputDevice {
            items.append(sliderItem(title: AudioSystem.name(of: device), icon: NSImage(systemSymbolName: "hifispeaker", accessibilityDescription: nil),
                value: Double(volume) * 100, max: 100, identifier: "") { AudioSystem.setOutputVolume(Float($0 / 100)) })
        }
        let apps = AudioSystem.apps()
        if apps.isEmpty {
            let empty = NSMenuItem(title: L("No apps using audio"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            items.append(empty)
        }
        for app in apps.prefix(12) {
            let icon = NSRunningApplication(processIdentifier: app.pid)?.icon
            let current = Double(gains[app.bundleID] ?? 1) * 100
            items.append(sliderItem(title: app.name, icon: icon, value: current, max: 150, identifier: app.bundleID) { [weak self] value in
                self?.setGain(Float(value / 100), bundleID: app.bundleID)
            })
        }
        return items
    }

    func settingsView() -> NSView {
        let reset = NSButton(title: L("Reset all apps to 100 %"), target: self, action: #selector(resetAll))
        return SettingsForm.stack([
            SettingsForm.note(L("Move an app's slider in the Nexo menu to change only its volume (up to 150 %, with a limiter to avoid distortion). macOS asks once for “System Audio Recording” permission: Nexo captures the app's audio and plays it back at the new level.")),
            SettingsForm.note(L("At 100 % nothing is captured. Apps with DRM-protected audio may not allow it.")),
            reset,
        ])
    }

    /// Looks the app up again: the menu's snapshot may be older than the processes it now has.
    private func setGain(_ gain: Float, bundleID: String) {
        var stored = gains
        stored[bundleID] = abs(gain - 1) < 0.01 ? nil : gain
        gains = stored
        if let tap = taps[bundleID], abs(gain - 1) >= 0.01 {
            tap.gain.value = gain
            return
        }
        guard let app = AudioSystem.apps().first(where: { $0.bundleID == bundleID }) else { return }
        apply(gain, to: app)
    }

    private func apply(_ gain: Float, to app: AudioApp) {
        if abs(gain - 1) < 0.01 {
            taps.removeValue(forKey: app.bundleID)?.stop()
            return
        }
        // Same set of processes → just retune; a new helper process needs a new tap to be captured.
        if let tap = taps[app.bundleID], Set(tap.app.objectIDs) == Set(app.objectIDs) {
            tap.gain.value = gain
            return
        }
        taps.removeValue(forKey: app.bundleID)?.stop()
        guard let device = AudioSystem.defaultOutputDevice, let tap = AppAudioTap(app: app, gain: gain, outputDevice: device) else {
            NSLog("Nexo: couldn't create audio tap for \(app.bundleID)")
            return
        }
        taps[app.bundleID] = tap
    }

    /// Re-creates taps for apps with a stored gain (new process, device switch) and drops taps of apps
    /// that quit.
    private func reconcile() {
        // A listener event queued before stop() must not recreate (muting) taps.
        guard isRunning else { return }
        let stored = gains
        let apps = AudioSystem.apps()
        let byBundle = Dictionary(apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        for bundleID in taps.keys where byBundle[bundleID] == nil {
            taps.removeValue(forKey: bundleID)?.stop()
        }
        for (bundleID, gain) in stored {
            guard let app = byBundle[bundleID] else { continue }
            apply(gain, to: app)
        }
    }

    private func rebuildAll() {
        taps.values.forEach { $0.stop() }
        taps.removeAll()
        reconcile()
        // A just-connected output (Bluetooth) may not accept an aggregate yet: retry once shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.reconcile() }
    }

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            let deviceChanged = (0..<Int(count)).contains { addresses[$0].mSelector == kAudioHardwarePropertyDefaultOutputDevice }
            DispatchQueue.main.async { deviceChanged ? self?.rebuildAll() : self?.reconcile() }
        }
        listenerBlock = block
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    private func removeListeners() {
        guard let listenerBlock else { return }
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listenerBlock)
        }
        self.listenerBlock = nil
    }

    private func sliderItem(title: String, icon: NSImage?, value: Double, max: Double, identifier: String, onChange: @escaping (Double) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MixerRowView(title: title, icon: icon, value: value, max: max, onChange: onChange)
        return item
    }

    @objc private func resetAll() {
        gains = [:]
        rebuildAll()
    }
}

/// Menu row: icon, name, slider and percentage. Sliders inside menus track continuously.
final class MixerRowView: NSView {
    private let onChange: (Double) -> Void
    private let percent = NSTextField(labelWithString: "")

    init(title: String, icon: NSImage?, value: Double, max: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        let image = NSImageView(image: icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
        image.widthAnchor.constraint(equalToConstant: 18).isActive = true
        image.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let name = NSTextField(labelWithString: title)
        name.lineBreakMode = .byTruncatingTail
        name.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let slider = NSSlider(value: value, minValue: 0, maxValue: max, target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        if max > 100 {
            slider.numberOfTickMarks = 4
            slider.allowsTickMarkValuesOnly = false
        }
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        percent.widthAnchor.constraint(equalToConstant: 36).isActive = true
        percent.stringValue = "\(Int(value.rounded()))%"
        let stack = NSStackView(views: [image, name, slider, percent])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    @objc private func sliderChanged(_ sender: NSSlider) {
        // Snap to 100 % near it so an app can be returned to "untouched" (no tap) easily.
        var value = sender.doubleValue
        if sender.maxValue > 100, abs(value - 100) < 3 {
            value = 100
            sender.doubleValue = 100
        }
        percent.stringValue = "\(Int(value.rounded()))%"
        onChange(value)
    }
}
