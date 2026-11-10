import Darwin
import Foundation

/// Reads integer sysctls. Injectable so the memory-pressure math can be tested with fixed values.
protocol SysctlReading {
    func int32(_ name: String) -> Int32?
}

struct SystemSysctl: SysctlReading {
    func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

/// The kernel's memory pressure, which is what Activity Monitor's "Memory Pressure" graph shows.
///
/// - Color comes ONLY from `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical),
///   the same signal Activity Monitor colors green/yellow/red. Stats instead fills and colors its
///   bar from occupancy, which is why it disagrees with Activity Monitor.
/// - The percentage is `100 − kern.memorystatus_level`; `memorystatus_level` is the "system-wide
///   memory free percentage" printed by the `memory_pressure` CLI.
/// Both sysctls are `int` (4 bytes); reading them into an 8-byte Int with a 4-byte size only works by
/// accident of zero-initialisation on little-endian (a Stats bug).
struct MemoryPressure: Equatable {
    enum Level: Int32 {
        case normal = 1
        case warning = 2
        case critical = 4
    }

    let level: Level
    /// 0–100, nil if the kernel didn't answer.
    let percent: Int?

    static func read(_ sysctl: SysctlReading = SystemSysctl()) -> MemoryPressure {
        let raw = sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1
        let level = Level(rawValue: raw) ?? (raw > 4 ? .critical : .normal)
        let percent = sysctl.int32("kern.memorystatus_level").map { min(100, max(0, 100 - Int($0))) }
        return MemoryPressure(level: level, percent: percent)
    }
}

/// Memory breakdown matching Activity Monitor's Memory tab.
/// "Memory Used" = App Memory + Wired + Compressed, where App Memory = internal − purgeable pages.
struct MemoryUsage: Equatable {
    let total: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let swapUsed: UInt64

    var used: UInt64 { app + wired + compressed }

    static func read() -> MemoryUsage? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        return MemoryUsage(
            total: ProcessInfo.processInfo.physicalMemory,
            app: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            swapUsed: swapUsed())
    }

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : 0
    }
}
