import Darwin
import Foundation
import IOKit
import IOKit.ps

/// CPU load since the previous sample: totals by state plus every core, in `host_processor_info` order
/// (on Apple Silicon the efficiency cluster comes first).
struct CPULoad: Equatable {
    var total: Double
    var user: Double
    var system: Double
    var idle: Double
    var perCore: [Double]
}

/// Core layout of the machine: how many of the first logical CPUs are efficiency cores.
enum CPUTopology {
    static let efficiencyCores: Int = {
        var name = [CChar](repeating: 0, count: 64)
        var size = name.count
        guard sysctlbyname("hw.perflevel1.name", &name, &size, nil, 0) == 0,
              String(cString: name) == "Efficiency" else { return 0 }
        var count: Int32 = 0
        var countSize = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &count, &countSize, nil, 0) == 0 ? Int(count) : 0
    }()
}

/// CPU usage from per-core tick counters; each `read()` returns the load since the previous call.
final class CPUReader {
    private var previous: [UInt64]?

    /// nil on the first call (no delta yet).
    func read() -> CPULoad? {
        guard let ticks = Self.ticks() else { return nil }
        defer { previous = ticks }
        guard let previous, previous.count == ticks.count else { return nil }
        return Self.load(previous: previous, current: ticks)
    }

    /// `ticks` is user, system, idle, nice per core, flattened. Exposed for tests.
    static func usage(previous: [UInt64], current: [UInt64]) -> Double {
        load(previous: previous, current: current).total
    }

    static func load(previous: [UInt64], current: [UInt64]) -> CPULoad {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var perCore = [Double]()
        for core in stride(from: 0, to: current.count, by: 4) {
            // Kernel counters are 32-bit: wrap the delta at 32 bits so a rollover can't trap.
            let delta = (0..<4).map { UInt64(UInt32(truncatingIfNeeded: current[core + $0] &- previous[core + $0])) }
            user += delta[0] + delta[3]
            system += delta[1]
            idle += delta[2]
            let total = delta.reduce(0, +)
            perCore.append(total == 0 ? 0 : Double(total - delta[2]) / Double(total))
        }
        let total = Double(user + system + idle)
        guard total > 0 else { return CPULoad(total: 0, user: 0, system: 0, idle: 1, perCore: perCore) }
        return CPULoad(total: Double(user + system) / total, user: Double(user) / total,
            system: Double(system) / total, idle: Double(idle) / total, perCore: perCore)
    }

    private static func ticks() -> [UInt64]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).flatMap { cpu -> [UInt64] in
            let base = cpu * states
            return [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE].map { UInt64(UInt32(bitPattern: info[base + Int($0)])) }
        }
    }
}

struct GPUStatus: Equatable {
    let device: Double
    let renderer: Double?
    let tiler: Double?
}

/// GPU utilization from the accelerator's `PerformanceStatistics` (no entitlement needed).
enum GPUReader {
    static func read() -> GPUStatus? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: GPUStatus?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let device = stats["Device Utilization %"] as? Int else { continue }
            let status = GPUStatus(device: Double(device) / 100,
                renderer: (stats["Renderer Utilization %"] as? Int).map { Double($0) / 100 },
                tiler: (stats["Tiler Utilization %"] as? Int).map { Double($0) / 100 })
            if best == nil || status.device > best!.device { best = status }
        }
        return best
    }
}

/// Network throughput summed over every non-loopback interface, in bytes per second.
final class NetworkReader {
    private var previous: (date: Date, input: UInt64, output: UInt64)?

    func read() -> (download: Double, upload: Double)? {
        guard let totals = Self.totals() else { return nil }
        let now = Date()
        defer { previous = (now, totals.input, totals.output) }
        guard let previous else { return nil }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return nil }
        return (Double(totals.input &- previous.input) / elapsed, Double(totals.output &- previous.output) / elapsed)
    }

    /// First IPv4 address of an active, non-loopback interface (en0 first), with its interface name.
    static func localAddress() -> (interface: String, address: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found = [(interface: String, address: String)]()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING), entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: entry.ifa_name), String(cString: host)))
        }
        return found.first { $0.interface.hasPrefix("en") } ?? found.first
    }

    private static func totals() -> (input: UInt64, output: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var input: UInt64 = 0
        var output: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            input += UInt64(data.pointee.ifi_ibytes)
            output += UInt64(data.pointee.ifi_obytes)
        }
        return (input, output)
    }
}

struct BatteryStatus: Equatable {
    let percent: Int
    let isCharging: Bool
    let onAC: Bool
    let cycleCount: Int?
}

enum BatteryReader {
    static func read() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return BatteryStatus(percent: current * 100 / max,
                isCharging: info[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                cycleCount: cycleCount())
        }
        return nil
    }

    private static func cycleCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }
}

/// Free space of the boot volume and disk throughput summed over every block storage driver.
final class DiskReader {
    private var previous: (date: Date, read: UInt64, written: UInt64)?

    static func freeSpace() -> (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }

    func throughput() -> (read: Double, write: Double)? {
        let totals = Self.totals()
        let now = Date()
        defer { previous = (now, totals.read, totals.written) }
        guard let previous else { return nil }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return nil }
        return (Double(totals.read &- previous.read) / elapsed, Double(totals.written &- previous.written) / elapsed)
    }

    private static func totals() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += stats["Bytes (Read)"] as? UInt64 ?? 0
            written += stats["Bytes (Write)"] as? UInt64 ?? 0
        }
        return (read, written)
    }
}
