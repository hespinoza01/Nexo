import Cocoa
import UserNotifications

struct ProcessUsage: Equatable {
    let pid: pid_t
    let name: String
    let cpu: Double
    let memory: UInt64
}

struct TopProcesses: Equatable {
    var byCPU = [ProcessUsage]()
    var byMemory = [ProcessUsage]()
}

/// Top processes by CPU and by memory from one `ps` snapshot. Only runs while the popover is open,
/// off the main thread.
enum TopProcessesReader {
    private static let queue = DispatchQueue(label: "com.luckylopolis.nexo.monitor.processes", qos: .utility)
    /// Main-thread only: skips a tick while the previous `ps` is still running.
    private static var inFlight = false

    /// `pcpu` is ps' decayed average (like `top`'s default), not the instantaneous value.
    static func read(limit: Int, completion: @escaping (TopProcesses) -> Void) {
        guard limit > 0 else { return completion(TopProcesses()) }
        guard !inFlight else { return }
        inFlight = true
        queue.async {
            let output = Shell.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm="], timeout: 3)?.output ?? ""
            let all = parse(output)
            let byCPU = Array(all.sorted { $0.cpu > $1.cpu }.prefix(limit))
            let byMemory = Array(all.sorted { $0.memory > $1.memory }.prefix(limit))
            DispatchQueue.main.async {
                inFlight = false
                // App names resolved on main and only for the few rows shown.
                let named = { (p: ProcessUsage) in
                    ProcessUsage(pid: p.pid, name: NSRunningApplication(processIdentifier: p.pid)?.localizedName ?? p.name, cpu: p.cpu, memory: p.memory)
                }
                completion(TopProcesses(byCPU: byCPU.map(named), byMemory: byMemory.map(named)))
            }
        }
    }

    /// Lines of `pid pcpu rss(KB) command`; the command may contain spaces. Exposed for tests.
    static func parse(_ output: String) -> [ProcessUsage] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = pid_t(fields[0]), let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = UInt64(fields[2]) else { return nil }
            return ProcessUsage(pid: pid, name: String(fields[3]).trimmingCharacters(in: .whitespaces), cpu: cpu, memory: rss * 1024)
        }
    }
}

/// Posts a notification on the transitions the user opted into: memory pressure rising to
/// warning/critical, CPU above a threshold for a sustained time, boot volume nearly full.
/// Each alert fires once per episode and re-arms when the condition clears.
final class MonitorAlerter {
    private var lastPressure = MemoryPressure.Level.normal
    private var cpuHighSince: Date?
    private var cpuNotified = false
    private var diskNotified = false
    private var authorized = false
    private let now: () -> Date
    private let post: (String, String) -> Void

    init(now: @escaping () -> Date = Date.init, post: ((String, String) -> Void)? = nil) {
        self.now = now
        self.post = post ?? Self.deliver
    }

    func requestAuthorizationIfNeeded(_ alerts: MonitorAlerts) {
        guard !authorized, alerts.memoryPressure || alerts.cpuSustained || alerts.lowDisk, Bundle.main.bundleIdentifier != nil else { return }
        authorized = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(_ sample: MonitorSample, _ alerts: MonitorAlerts) {
        evaluatePressure(sample.pressure.level, enabled: alerts.memoryPressure)
        evaluateCPU(sample.cpu, alerts)
        evaluateDisk(sample.diskFree, alerts)
    }

    private func evaluatePressure(_ level: MemoryPressure.Level, enabled: Bool) {
        defer { lastPressure = level }
        guard enabled, level.rawValue > lastPressure.rawValue else { return }
        post(L("Memory pressure %@", MonitorModule.levelName(level)),
             level == .critical ? L("macOS is running out of memory. Close apps you don't need.") : L("Memory is getting tight; macOS has started compressing and swapping."))
    }

    private func evaluateCPU(_ cpu: Double?, _ alerts: MonitorAlerts) {
        guard alerts.cpuSustained, let cpu, cpu >= alerts.cpuThreshold else {
            cpuHighSince = nil
            cpuNotified = false
            return
        }
        let since = cpuHighSince ?? now()
        cpuHighSince = since
        guard !cpuNotified, now().timeIntervalSince(since) >= alerts.cpuSeconds else { return }
        cpuNotified = true
        post(L("High CPU usage"), L("CPU has been above %@ for %d s.", MonitorFormat.percent(alerts.cpuThreshold), Int(alerts.cpuSeconds)))
    }

    private func evaluateDisk(_ disk: (free: Int64, total: Int64)?, _ alerts: MonitorAlerts) {
        guard alerts.lowDisk, let disk, disk.total > 0, disk.free >= 0 else { return }
        let freeFraction = Double(disk.free) / Double(disk.total)
        guard freeFraction < alerts.lowDiskFraction else {
            // Hysteresis: re-arm only once clearly above the threshold, so hovering around it is quiet.
            if freeFraction > alerts.lowDiskFraction + 0.02 { diskNotified = false }
            return
        }
        guard !diskNotified else { return }
        diskNotified = true
        post(L("Disk almost full"), L("Only %@ free on the startup disk.", MonitorFormat.bytes(UInt64(disk.free))))
    }

    private static func deliver(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
