import Foundation

/// Runs external tools with an argument array (never a shell string), so device names and ids with
/// spaces or quotes can't inject anything. A GUI app doesn't inherit the login shell's PATH, so
/// tools are resolved to absolute paths by the callers.
enum Shell {
    struct Result {
        let status: Int32
        let output: String
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }

    /// Starts a long-running process (an emulator) without waiting for it.
    static func launch(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

struct SimulatorDevice: Equatable {
    enum Platform { case ios, android }

    let platform: Platform
    let id: String
    let name: String
    let runtime: String
    let isBooted: Bool
}

/// iOS / watchOS / tvOS / visionOS simulators through `xcrun simctl`.
enum IOSDeviceService {
    private static let xcrun = "/usr/bin/xcrun"

    static func devices() -> [SimulatorDevice] {
        guard let result = Shell.run(xcrun, ["simctl", "list", "devices", "available", "-j"]), result.status == 0 else { return [] }
        return parse(Data(result.output.utf8))
    }

    /// Parses `simctl list devices -j`. Exposed for tests.
    static func parse(_ json: Data) -> [SimulatorDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        return byRuntime.flatMap { runtime, devices in
            devices.compactMap { device -> SimulatorDevice? in
                guard let udid = device["udid"] as? String, let name = device["name"] as? String,
                      device["isAvailable"] as? Bool ?? true else { return nil }
                return SimulatorDevice(platform: .ios, id: udid, name: name, runtime: runtimeName(runtime),
                    isBooted: device["state"] as? String == "Booted")
            }
        }.sorted { ($0.runtime, $0.name) > ($1.runtime, $1.name) }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-1" → "iOS 26.1"
    static func runtimeName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return String(last) }
        return "\(os) \(parts.dropFirst().joined(separator: "."))"
    }

    static func boot(_ device: SimulatorDevice) {
        Shell.run(xcrun, ["simctl", "boot", device.id])
        Shell.run("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device.id])
    }

    static func shutdown(_ device: SimulatorDevice) {
        Shell.run(xcrun, ["simctl", "shutdown", device.id])
    }
}

/// Android emulators through the SDK's `emulator` and `adb` binaries.
enum AndroidDeviceService {
    static let sdkPathKey = "simulators.androidSdkPath"

    static var sdkPath: String {
        if let stored = UserDefaults.standard.string(forKey: sdkPathKey), !stored.isEmpty { return stored }
        if let env = ProcessInfo.processInfo.environment["ANDROID_HOME"], !env.isEmpty { return env }
        return NSHomeDirectory() + "/Library/Android/sdk"
    }

    private static var emulator: String { sdkPath + "/emulator/emulator" }
    private static var adb: String { sdkPath + "/platform-tools/adb" }

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: emulator) }

    static func devices() -> [SimulatorDevice] {
        guard isAvailable, let list = Shell.run(emulator, ["-list-avds"]) else { return [] }
        let running = runningAvdNames()
        return parseAvds(list.output).map {
            SimulatorDevice(platform: .android, id: $0, name: $0.replacingOccurrences(of: "_", with: " "),
                runtime: "Android", isBooted: running.contains($0))
        }
    }

    /// One AVD name per line; the emulator sometimes prints INFO lines first. Exposed for tests.
    static func parseAvds(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("INFO") && !$0.contains(" ") }
    }

    static func boot(_ device: SimulatorDevice) {
        Shell.launch(emulator, ["-avd", device.id])
    }

    static func shutdown(_ device: SimulatorDevice) {
        guard let serial = serials()[device.id] else { return }
        Shell.run(adb, ["-s", serial, "emu", "kill"])
    }

    private static func runningAvdNames() -> Set<String> {
        Set(serials().keys)
    }

    /// AVD name → adb serial for running emulators.
    private static func serials() -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: adb), let result = Shell.run(adb, ["devices"]) else { return [:] }
        let emulators = result.output.split(whereSeparator: \.isNewline)
            .compactMap { $0.split(separator: "\t").first.map(String.init) }
            .filter { $0.hasPrefix("emulator-") }
        var map = [String: String]()
        for serial in emulators {
            guard let name = Shell.run(adb, ["-s", serial, "emu", "avd", "name"], timeout: 5)?.output
                .split(whereSeparator: \.isNewline).first.map(String.init) else { continue }
            map[name.trimmingCharacters(in: .whitespaces)] = serial
        }
        return map
    }
}
