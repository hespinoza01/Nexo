import Foundation

// Private IOKit HID event-system API (exported by IOKit.framework, no public header). On Apple Silicon
// this is the only unprivileged way to read die temperatures; Stats declares the same functions in its
// `Modules/Sensors/bridge.h`. Signatures as used there; may change between macOS versions.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

/// Apple Silicon temperature sensors (CPU/GPU die "PMU tdie*" / "tdev*"). Read-only, no helper needed.
enum TemperatureReader {
    private static let temperatureEventType: Int64 = 15 // kIOHIDEventTypeTemperature
    private static let client: CFTypeRef? = {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Usage page 0xff00 / usage 5: Apple vendor-defined temperature sensors.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(client, matching)
        return client
    }()

    /// Average and maximum of the die sensors, in °C. nil when the API isn't available.
    static func read() -> (average: Double, maximum: Double)? {
        let values = sensors().filter { $0.name.contains("tdie") }.map(\.celsius)
        let readings = values.isEmpty ? sensors().map(\.celsius) : values
        guard !readings.isEmpty, let maximum = readings.max() else { return nil }
        return (readings.reduce(0, +) / Double(readings.count), maximum)
    }

    static func sensors() -> [(name: String, celsius: Double)] {
        guard let client, let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return services.compactMap { service in
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = IOHIDServiceClientCopyEvent(service, temperatureEventType, 0, 0)?.takeRetainedValue() else { return nil }
            let value = IOHIDEventGetFloatValue(event, Int32(temperatureEventType << 16))
            // Disconnected sensors report 0 or absurd values.
            guard value > 0, value < 150 else { return nil }
            return (name, value)
        }
    }
}
