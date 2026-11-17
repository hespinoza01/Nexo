import Cocoa
import Darwin

/// What a row in the Processes tab is: a regular app (Dock/windows), a background process of the
/// current user (agents, helpers, daemons), or a process owned by another user (root, _daemons).
enum ProcessKind: String, CaseIterable {
    case app, background, system
}

struct ProcessEntry: Equatable, Identifiable {
    let pid: pid_t
    let uid: uid_t
    var name: String
    var kind: ProcessKind
    /// Bytes. Physical footprint (like Activity Monitor) for the user's own processes, RSS otherwise.
    var memory: UInt64?
    /// Percent of one core, `ps`' decayed average.
    var cpu: Double
    /// Disk read + write, bytes per second since the previous refresh. Nil for the first refresh
    /// and for processes of other users (the kernel denies their counters).
    var diskRate: Double?
    var isUnresponsive: Bool
    /// Process start time in microseconds since 1970. Identifies the process across pid reuse.
    var startTime: UInt64?
    var bundleID: String?

    var id: pid_t { pid }
}

/// Everything known about one running app, captured on the main thread.
struct RunningAppInfo: Equatable {
    let name: String
    let bundleID: String?
    let policy: NSApplication.ActivationPolicy
}

/// Raw `ps` line.
struct PSRow: Equatable {
    let pid: pid_t
    let uid: uid_t
    let cpu: Double
    let rss: UInt64
    let command: String
}

/// Kernel counters of one of the user's own processes.
struct ProcessIOSample: Equatable {
    let footprint: UInt64
    let diskBytes: UInt64
}

/// Disk counter of a process at a given time; the next refresh turns the difference into a rate.
struct DiskMark: Equatable {
    let bytes: UInt64
    let time: TimeInterval
}

/// Pure building blocks plus a reader that runs `ps` and the kernel queries off the main thread.
/// It only runs while the Processes tab is on screen.
final class ProcessListReader {
    private let queue = DispatchQueue(label: "com.luckylopolis.nexo.monitor.processlist", qos: .utility)
    /// Main-thread only.
    private var inFlight = false
    /// Accessed only on `queue`. Keyed by pid and start time so a reused pid starts over.
    private var marks = [String: DiskMark]()
    /// Accessed only on `queue`. Apps that missed the previous check too; a single slow answer
    /// (launching, a brief stall) isn't reported.
    private var suspects = Set<pid_t>()

    /// Skips the call while the previous read is still running. `completion` runs on main.
    func read(completion: @escaping ([ProcessEntry]) -> Void) {
        guard !inFlight else { return }
        inFlight = true
        let apps = Self.runningApps()
        queue.async { [weak self] in
            guard let self else { return }
            let began = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let output = Shell.run("/bin/ps", ["-Aceo", "pid=,uid=,pcpu=,rss=,comm="], timeout: 3)?.output ?? ""
            let rows = Self.parse(output)
            let me = getuid()
            var io = [pid_t: ProcessIOSample]()
            var starts = [pid_t: UInt64]()
            var names = [pid_t: String]()
            for row in rows {
                if row.uid == me, let sample = Self.ioSample(row.pid) { io[row.pid] = sample }
                // A start after `ps` ran means the pid was reused in between: the row describes the old
                // process, so it gets no identity and can't be stopped.
                if let start = ProcessIdentity.startTime(row.pid), start <= began { starts[row.pid] = start }
                if let name = Self.executableName(row.pid) { names[row.pid] = name }
            }
            var unresponsive = Set<pid_t>()
            for (pid, app) in apps where app.policy == .regular && UnresponsiveDetector.isUnresponsive(pid) {
                unresponsive.insert(pid)
            }
            let confirmed = unresponsive.intersection(self.suspects)
            self.suspects = unresponsive
            let built = Self.build(rows: rows, apps: apps, io: io, starts: starts, names: names, unresponsive: confirmed,
                                   previous: self.marks, now: ProcessInfo.processInfo.systemUptime, me: me)
            self.marks = built.marks
            DispatchQueue.main.async {
                self.inFlight = false
                completion(built.entries)
            }
        }
    }

    /// Lines of `pid uid pcpu rss(KB) command`; the command may contain spaces. Exposed for tests.
    static func parse(_ output: String) -> [PSRow] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = pid_t(fields[0]), pid >= 0, let uid = uid_t(fields[1]),
                  let cpu = Double(fields[2].replacingOccurrences(of: ",", with: ".")), let rss = UInt64(fields[3]) else { return nil }
            let command = String(fields[4]).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            return PSRow(pid: pid, uid: uid, cpu: cpu, rss: rss * 1024, command: command)
        }
    }

    static func kind(uid: uid_t, me: uid_t, policy: NSApplication.ActivationPolicy?) -> ProcessKind {
        if policy == .regular { return .app }
        return uid == me ? .background : .system
    }

    /// Bytes per second between two readings of a monotonic counter. Nil without a usable previous
    /// reading; a counter that went backwards (process restarted) counts as idle.
    static func diskRate(previous: DiskMark?, current: DiskMark) -> Double? {
        guard let previous, current.time > previous.time else { return nil }
        guard current.bytes >= previous.bytes else { return 0 }
        return Double(current.bytes - previous.bytes) / (current.time - previous.time)
    }

    static func markKey(pid: pid_t, start: UInt64?) -> String { "\(pid):\(start ?? 0)" }

    /// Merges every source into rows. Pure; exposed for tests.
    static func build(rows: [PSRow], apps: [pid_t: RunningAppInfo], io: [pid_t: ProcessIOSample], starts: [pid_t: UInt64],
                      names: [pid_t: String] = [:], unresponsive: Set<pid_t>, previous: [String: DiskMark], now: TimeInterval, me: uid_t)
        -> (entries: [ProcessEntry], marks: [String: DiskMark]) {
        var marks = [String: DiskMark]()
        let entries = rows.map { row -> ProcessEntry in
            let app = apps[row.pid]
            let start = starts[row.pid]
            var rate: Double?
            var memory: UInt64? = row.rss > 0 ? row.rss : nil
            if let sample = io[row.pid] {
                let key = markKey(pid: row.pid, start: start)
                let mark = DiskMark(bytes: sample.diskBytes, time: now)
                rate = diskRate(previous: previous[key], current: mark)
                marks[key] = mark
                memory = sample.footprint
            }
            return ProcessEntry(pid: row.pid, uid: row.uid, name: app?.name ?? names[row.pid] ?? row.command,
                                kind: kind(uid: row.uid, me: me, policy: app?.policy), memory: memory, cpu: row.cpu,
                                diskRate: rate, isUnresponsive: unresponsive.contains(row.pid), startTime: start,
                                bundleID: app?.bundleID)
        }
        return (entries, marks)
    }

    /// `ps -c` truncates to 16 characters; the executable path has the full name.
    static func executableName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = (String(cString: buffer) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func ioSample(_ pid: pid_t) -> ProcessIOSample? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        return ProcessIOSample(footprint: info.ri_phys_footprint, diskBytes: info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten)
    }

    private static func runningApps() -> [pid_t: RunningAppInfo] {
        var apps = [pid_t: RunningAppInfo]()
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier > 0 {
            apps[app.processIdentifier] = RunningAppInfo(name: app.localizedName ?? app.bundleIdentifier ?? "",
                                                         bundleID: app.bundleIdentifier, policy: app.activationPolicy)
        }
        return apps
    }
}

enum ProcessIdentity {
    /// Start time of `pid` in microseconds since 1970, from `sysctl` (allowed for every user's process).
    static func startTime(_ pid: pid_t) -> UInt64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }
}

/// "Not responding": the app's main thread doesn't answer. Two signals, either is enough:
/// - WindowServer's flag (private, resolved at runtime), which the Dock and Force Quit window use. On
///   macOS 27.2 it stayed false for a stopped app even with clicks queued, so it can't be the only one.
/// - An Accessibility query with a short timeout: AppKit answers it on the main thread, so a blocked
///   app times out (`cannotComplete`). Without Accessibility trust the call fails fast and is ignored.
enum UnresponsiveDetector {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CheckFn = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    private typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    static let accessibilityTimeout: Float = 0.25

    private static let functions: (connection: ConnectionFn, check: CheckFn, psn: PSNFn)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let check = dlsym(handle, "CGSEventIsAppUnresponsive"),
              let psn = dlsym(handle, "GetProcessForPID") else { return nil }
        return (unsafeBitCast(connection, to: ConnectionFn.self), unsafeBitCast(check, to: CheckFn.self), unsafeBitCast(psn, to: PSNFn.self))
    }()

    static func isUnresponsive(_ pid: pid_t) -> Bool {
        windowServerFlag(pid) || accessibilityTimesOut(pid)
    }

    private static func windowServerFlag(_ pid: pid_t) -> Bool {
        guard let functions else { return false }
        var psn = ProcessSerialNumber()
        guard functions.psn(pid, &psn) == noErr else { return false }
        return functions.check(functions.connection(), &psn)
    }

    private static func accessibilityTimesOut(_ pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, accessibilityTimeout)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &value) == .cannotComplete
    }
}

enum ProcessSort: String, CaseIterable {
    case memory, disk, cpu, name
}

enum ProcessFilter: String, CaseIterable {
    case all, apps, background, system

    func includes(_ kind: ProcessKind) -> Bool {
        switch self {
        case .all: return true
        case .apps: return kind == .app
        case .background: return kind == .background
        case .system: return kind == .system
        }
    }
}

/// Filter, search and order of the Processes tab. Apps that don't respond always come first;
/// rows without a value for the sort key go last in either direction.
struct ProcessQuery: Equatable {
    var filter = ProcessFilter.all
    var search = ""
    var sort = ProcessSort.memory
    var ascending = false

    func apply(_ entries: [ProcessEntry]) -> [ProcessEntry] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = pid_t(term)
        return entries
            .filter { filter.includes($0.kind) }
            .filter { term.isEmpty || $0.pid == pid || $0.name.localizedCaseInsensitiveContains(term) }
            .sorted(by: precedes)
    }

    private func precedes(_ a: ProcessEntry, _ b: ProcessEntry) -> Bool {
        if a.isUnresponsive != b.isUnresponsive { return a.isUnresponsive }
        if sort == .name {
            let order = a.name.localizedStandardCompare(b.name)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            return a.pid < b.pid
        }
        let lhs = value(a), rhs = value(b)
        switch (lhs, rhs) {
        case let (l?, r?) where l != r: return ascending ? l < r : l > r
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.pid < b.pid : order == .orderedAscending
        }
    }

    private func value(_ entry: ProcessEntry) -> Double? {
        switch sort {
        case .memory: return entry.memory.map(Double.init)
        case .disk: return entry.diskRate
        case .cpu: return entry.cpu
        case .name: return nil
        }
    }
}
