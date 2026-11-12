import AppKit
import CoreAudio

/// Thin CoreAudio property helpers.
enum CoreAudioProperty {
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    static func write<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T,
                         scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value = value
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        guard read(object, selector, &value), let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// An app as the user sees it, with every CoreAudio process object that belongs to it: browsers and
/// Electron apps play audio from helper processes (`com.microsoft.edgemac.helper`), not the main app.
struct AudioApp: Equatable {
    let objectIDs: [AudioObjectID]
    let pid: pid_t
    let bundleID: String
    let name: String
    let isPlaying: Bool
}

enum AudioSystem {
    /// "com.google.Chrome.helper.Renderer" → "com.google.Chrome"; other ids unchanged.
    static func familyID(_ bundleID: String) -> String {
        // ".helper" as a whole component: "com.acme.helpertools" is not a helper.
        let components = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.lowercased() == "helper" }), index > 0 else { return bundleID }
        return components[..<index].joined(separator: ".")
    }

    /// Apps with CoreAudio process objects, grouped by family, the ones playing first.
    static func apps() -> [AudioApp] {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let objects = CoreAudioProperty.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        var families = [String: (objects: [AudioObjectID], playing: Bool, mainPid: pid_t?, anyPid: pid_t)]()
        for object in objects {
            var pid: pid_t = 0
            guard CoreAudioProperty.read(object, kAudioProcessPropertyPID, &pid), pid > 0, pid != ownPid,
                  let bundleID = CoreAudioProperty.string(object, kAudioProcessPropertyBundleID), !bundleID.isEmpty else { continue }
            var running: UInt32 = 0
            _ = CoreAudioProperty.read(object, kAudioProcessPropertyIsRunningOutput, &running)
            let family = familyID(bundleID)
            var entry = families[family] ?? ([], false, nil, pid)
            entry.objects.append(object)
            entry.playing = entry.playing || running != 0
            if bundleID == family { entry.mainPid = pid }
            families[family] = entry
        }
        return families.compactMap { family, entry -> AudioApp? in
            let pid = entry.mainPid ?? NSRunningApplication.runningApplications(withBundleIdentifier: family).first?.processIdentifier ?? entry.anyPid
            let app = NSRunningApplication(processIdentifier: pid)
            guard app?.activationPolicy == .regular || entry.playing else { return nil }
            return AudioApp(objectIDs: entry.objects, pid: pid, bundleID: family,
                name: app?.localizedName?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}").union(.whitespaces)) ?? family,
                isPlaying: entry.playing)
        }.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
    }

    static var defaultOutputDevice: AudioObjectID? {
        var device = AudioObjectID(0)
        guard CoreAudioProperty.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device), device != 0 else { return nil }
        return device
    }

    static func uid(of device: AudioObjectID) -> String? {
        CoreAudioProperty.string(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(of device: AudioObjectID) -> String {
        CoreAudioProperty.string(device, kAudioObjectPropertyName) ?? L("Output")
    }

    /// Output volume 0–1 of the default device: the main element when it has one, else channel 1.
    static var outputVolume: Float? {
        guard let device = defaultOutputDevice else { return nil }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var volume: Float32 = 0
            if CoreAudioProperty.read(device, kAudioDevicePropertyVolumeScalar, &volume, scope: kAudioDevicePropertyScopeOutput, element: element) {
                return volume
            }
        }
        return nil
    }

    static func setOutputVolume(_ volume: Float) {
        guard let device = defaultOutputDevice else { return }
        let value = Float32(max(0, min(1, volume)))
        if CoreAudioProperty.write(device, kAudioDevicePropertyVolumeScalar, value, scope: kAudioDevicePropertyScopeOutput, element: kAudioObjectPropertyElementMain) { return }
        for channel: AudioObjectPropertyElement in [1, 2] {
            _ = CoreAudioProperty.write(device, kAudioDevicePropertyVolumeScalar, value, scope: kAudioDevicePropertyScopeOutput, element: channel)
        }
    }
}
