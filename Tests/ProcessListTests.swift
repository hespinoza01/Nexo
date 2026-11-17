import XCTest
@testable import Nexo

final class ProcessListTests: XCTestCase {
    private func entry(_ pid: pid_t, _ name: String, kind: ProcessKind = .background, memory: UInt64? = nil, cpu: Double = 0,
                       disk: Double? = nil, hung: Bool = false, start: UInt64? = 1, uid: uid_t = 501) -> ProcessEntry {
        ProcessEntry(pid: pid, uid: uid, name: name, kind: kind, memory: memory, cpu: cpu, diskRate: disk,
                     isUnresponsive: hung, startTime: start, bundleID: nil)
    }

    // MARK: parse / build

    func testParseKeepsCommandsWithSpacesAndSkipsBadLines() {
        let output = """
          1     0   0.0  12000 launchd
        512   501   3,5   2048 Google Chrome Helper
        garbage line
        700   501   abc    10 broken
        """
        let rows = ProcessListReader.parse(output)
        XCTAssertEqual(rows, [
            PSRow(pid: 1, uid: 0, cpu: 0, rss: 12000 * 1024, command: "launchd"),
            PSRow(pid: 512, uid: 501, cpu: 3.5, rss: 2048 * 1024, command: "Google Chrome Helper"),
        ])
    }

    func testDiskRate() {
        XCTAssertNil(ProcessListReader.diskRate(previous: nil, current: DiskMark(bytes: 10, time: 1)))
        XCTAssertNil(ProcessListReader.diskRate(previous: DiskMark(bytes: 10, time: 1), current: DiskMark(bytes: 20, time: 1)))
        XCTAssertEqual(ProcessListReader.diskRate(previous: DiskMark(bytes: 1000, time: 1), current: DiskMark(bytes: 5000, time: 3)), 2000)
        XCTAssertEqual(ProcessListReader.diskRate(previous: DiskMark(bytes: 5000, time: 1), current: DiskMark(bytes: 10, time: 2)), 0)
    }

    func testKind() {
        XCTAssertEqual(ProcessListReader.kind(uid: 501, me: 501, policy: .regular), .app)
        XCTAssertEqual(ProcessListReader.kind(uid: 501, me: 501, policy: .accessory), .background)
        XCTAssertEqual(ProcessListReader.kind(uid: 501, me: 501, policy: nil), .background)
        XCTAssertEqual(ProcessListReader.kind(uid: 0, me: 501, policy: nil), .system)
    }

    func testBuildMergesSourcesAndComputesRateOnSecondRead() {
        let rows = [PSRow(pid: 10, uid: 501, cpu: 1, rss: 4096, command: "Notes"), PSRow(pid: 20, uid: 0, cpu: 2, rss: 8192, command: "syslogd")]
        let apps = [pid_t(10): RunningAppInfo(name: "Notas", bundleID: "com.apple.Notes", policy: .regular)]
        let first = ProcessListReader.build(rows: rows, apps: apps, io: [10: ProcessIOSample(footprint: 9999, diskBytes: 100)],
                                            starts: [10: 7, 20: 8], unresponsive: [10], previous: [:], now: 1, me: 501)
        XCTAssertEqual(first.entries.map(\.name), ["Notas", "syslogd"])
        XCTAssertEqual(first.entries[0].kind, .app)
        XCTAssertEqual(first.entries[0].memory, 9999)
        XCTAssertNil(first.entries[0].diskRate)
        XCTAssertTrue(first.entries[0].isUnresponsive)
        XCTAssertEqual(first.entries[1].kind, .system)
        XCTAssertEqual(first.entries[1].memory, 8192)
        XCTAssertNil(first.entries[1].diskRate)

        let second = ProcessListReader.build(rows: rows, apps: apps, io: [10: ProcessIOSample(footprint: 9999, diskBytes: 300)],
                                             starts: [10: 7, 20: 8], unresponsive: [], previous: first.marks, now: 3, me: 501)
        XCTAssertEqual(second.entries[0].diskRate, 100)

        let reused = ProcessListReader.build(rows: rows, apps: apps, io: [10: ProcessIOSample(footprint: 1, diskBytes: 500)],
                                             starts: [10: 99], unresponsive: [], previous: second.marks, now: 5, me: 501)
        XCTAssertNil(reused.entries[0].diskRate, "a reused pid starts its counter over")
    }

    // MARK: query

    func testUnresponsiveFirstInEverySort() {
        let entries = [entry(1, "Big", memory: 900, cpu: 90, disk: 900), entry(2, "Hung", memory: 1, cpu: 0, disk: 0, hung: true),
                       entry(3, "Alpha", memory: 500, cpu: 50, disk: 500)]
        for sort in ProcessSort.allCases {
            for ascending in [true, false] {
                let result = ProcessQuery(sort: sort, ascending: ascending).apply(entries)
                XCTAssertEqual(result.first?.pid, 2, "\(sort) ascending=\(ascending)")
            }
        }
    }

    func testSortsByValueAndPutsMissingValuesLast() {
        let entries = [entry(1, "A", memory: 100), entry(2, "B", memory: nil), entry(3, "C", memory: 300)]
        XCTAssertEqual(ProcessQuery(sort: .memory, ascending: false).apply(entries).map(\.pid), [3, 1, 2])
        XCTAssertEqual(ProcessQuery(sort: .memory, ascending: true).apply(entries).map(\.pid), [1, 3, 2])
        XCTAssertEqual(ProcessQuery(sort: .name, ascending: true).apply(entries).map(\.pid), [1, 2, 3])
        XCTAssertEqual(ProcessQuery(sort: .name, ascending: false).apply(entries).map(\.pid), [3, 2, 1])
    }

    func testFilterAndSearch() {
        let entries = [entry(10, "Safari", kind: .app), entry(20, "mdworker", kind: .background), entry(30, "syslogd", kind: .system, uid: 0)]
        XCTAssertEqual(ProcessQuery(filter: .apps).apply(entries).map(\.pid), [10])
        XCTAssertEqual(ProcessQuery(filter: .background).apply(entries).map(\.pid), [20])
        XCTAssertEqual(ProcessQuery(filter: .system).apply(entries).map(\.pid), [30])
        XCTAssertEqual(ProcessQuery(filter: .all).apply(entries).count, 3)
        XCTAssertEqual(ProcessQuery(search: "SAF").apply(entries).map(\.pid), [10])
        XCTAssertEqual(ProcessQuery(search: " 20 ").apply(entries).map(\.pid), [20])
        XCTAssertTrue(ProcessQuery(filter: .apps, search: "sys").apply(entries).isEmpty)
    }

    // MARK: terminator

    func testProtectedProcessesCannotBeTerminated() {
        XCTAssertFalse(ProcessTerminator.canTerminate(entry(0, "kernel_task", kind: .system, uid: 0), ownPID: 999))
        XCTAssertFalse(ProcessTerminator.canTerminate(entry(1, "launchd", kind: .system, uid: 0), ownPID: 999))
        XCTAssertFalse(ProcessTerminator.canTerminate(entry(150, "WindowServer", kind: .system, uid: 88), ownPID: 999))
        XCTAssertFalse(ProcessTerminator.canTerminate(entry(151, "loginwindow"), ownPID: 999))
        XCTAssertFalse(ProcessTerminator.canTerminate(entry(999, "Nexo", kind: .app), ownPID: 999))
        XCTAssertFalse(ProcessTerminator.canTerminate(entry(500, "nostart", start: nil), ownPID: 999))
        XCTAssertTrue(ProcessTerminator.canTerminate(entry(500, "Safari", kind: .app), ownPID: 999))
        XCTAssertTrue(ProcessTerminator.canTerminate(entry(501, "syslogd", kind: .system, uid: 0), ownPID: 999))
    }

    func testIdentityRejectsDifferentStart() {
        let listed = entry(500, "Safari", start: 1234)
        XCTAssertTrue(ProcessTerminator.isSameProcess(listed, currentStart: 1234))
        XCTAssertFalse(ProcessTerminator.isSameProcess(listed, currentStart: 5678))
        XCTAssertFalse(ProcessTerminator.isSameProcess(listed, currentStart: nil))
    }

    func testStartTimeOfCurrentProcess() {
        XCTAssertNotNil(ProcessIdentity.startTime(getpid()))
        XCTAssertNil(ProcessIdentity.startTime(-5))
    }

    func testAdminScriptPassesValuesAsArguments() {
        let arguments = ProcessTerminator.adminArguments(pid: 42, mode: .force, started: "Tue Nov 17 06:47:46 2026")
        XCTAssertEqual(Array(arguments.suffix(3)), ["KILL", "42", "Tue Nov 17 06:47:46 2026"])
        let script = arguments.dropLast(3).filter { $0 != "-e" }.joined(separator: "\n")
        XCTAssertFalse(script.contains("42"))
        XCTAssertTrue(script.contains("quoted form of (item 2 of argv)"))
        XCTAssertTrue(script.contains("with administrator privileges"))
    }

    func testAdminResultParsing() {
        XCTAssertEqual(ProcessTerminator.adminResult("ok\n"), .sent)
        XCTAssertEqual(ProcessTerminator.adminResult("gone"), .gone)
        XCTAssertEqual(ProcessTerminator.adminResult("cancelled"), .cancelled)
        XCTAssertEqual(ProcessTerminator.adminResult("error:Operation not permitted"), .failed("Operation not permitted"))
        if case .failed = ProcessTerminator.adminResult(nil) {} else { XCTFail("nil output must fail") }
        if case .failed = ProcessTerminator.adminResult("") {} else { XCTFail("empty output must fail") }
    }

    func testNormalizedStartMatchesXargs() {
        XCTAssertEqual(ProcessTerminator.normalizedStart("Mon Jan  1 00:00:00 2001    \n"), "Mon Jan 1 00:00:00 2001")
        XCTAssertNil(ProcessTerminator.normalizedStart("  \n"))
    }

    func testFullExecutableNameWinsOverTruncatedCommand() {
        let rows = [PSRow(pid: 10, uid: 501, cpu: 0, rss: 1, command: "Google Chrome He")]
        let built = ProcessListReader.build(rows: rows, apps: [:], io: [:], starts: [:], names: [10: "Google Chrome Helper (Renderer)"],
                                            unresponsive: [], previous: [:], now: 1, me: 501)
        XCTAssertEqual(built.entries.first?.name, "Google Chrome Helper (Renderer)")
        XCTAssertEqual(ProcessListReader.executablePath(getpid()).map { !$0.isEmpty }, true)
    }

    func testDisplayNameKeepsProcessNameUnlessTruncated() {
        XCTAssertEqual(ProcessListReader.displayName(command: "claude", path: "/Users/me/.local/share/claude/versions/2.1.326"), "claude")
        XCTAssertEqual(ProcessListReader.displayName(command: "Google Chrome H", path: "/A/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"),
                       "Google Chrome Helper (GPU)")
        XCTAssertEqual(ProcessListReader.displayName(command: "com.apple.WebKi", path: "/S/X.xpc/Contents/MacOS/com.apple.WebKit.WebContent"), "com.apple.WebKit.WebContent")
        XCTAssertEqual(ProcessListReader.displayName(command: "ShortButUnrelat", path: "/bin/other"), "ShortButUnrelat")
        XCTAssertEqual(ProcessListReader.displayName(command: "node", path: nil), "node")
    }

    func testBuildResolvesOwnerAndSearchMatchesIt() {
        let rows = [PSRow(pid: 30, uid: 501, cpu: 0, rss: 1, command: "claude")]
        let apps = [pid_t(9): RunningAppInfo(name: "Warp", bundleID: "dev.warp.Warp-Stable", policy: .regular)]
        let built = ProcessListReader.build(rows: rows, apps: apps, io: [:], starts: [:], owners: [30: 9], unresponsive: [], previous: [:], now: 1, me: 501)
        XCTAssertEqual(built.entries.first?.owner, "Warp")
        XCTAssertEqual(ProcessQuery(search: "warp").apply(built.entries).map(\.pid), [30])
    }

    func testAdminScriptCompiles() throws {
        let arguments = ProcessTerminator.adminArguments(pid: 42, mode: .quit, started: "Tue Nov 17 06:47:46 2026")
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nexo-kill-\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = Shell.run("/usr/bin/osacompile", ["-o", output.path] + arguments.dropLast(3), timeout: 20)
        XCTAssertEqual(result?.status, 0)
    }

    func testParseArgumentsKeepsArgvOnly() {
        let data = procargs(argc: 3, path: "/usr/local/bin/node", argv: ["node", "server.js", "--port=3000"], env: ["SECRET=abc"])
        XCTAssertEqual(ProcessDetailsReader.parseArguments(data), ["node", "server.js", "--port=3000"])
        XCTAssertNil(ProcessDetailsReader.parseArguments([1, 0]))

        var empty = withUnsafeBytes(of: Int32(3)) { Array($0) }
        for part in ["/bin/foo", "", "foo", "--name", "", "SECRET=abc"] { empty += Array(part.utf8) + [0] }
        XCTAssertNil(ProcessDetailsReader.parseArguments(empty), "path end not padded to the boundary")
    }

    /// Layouts copied from real `KERN_PROCARGS2` buffers: the string area starts at offset 4 and argv
    /// begins at the next 8-byte boundary after the executable path.
    private func procargs(argc: Int32, path: String, argv: [String], env: [String]) -> [UInt8] {
        var data = withUnsafeBytes(of: argc) { Array($0) } + Array(path.utf8) + [0]
        while (data.count - 4) % 8 != 0 { data.append(0) }
        for part in argv + env { data += Array(part.utf8) + [0] }
        return data
    }

    func testParseArgumentsWithEmptyArguments() {
        // Exact bytes of `/bin/sleep` exec'd with argv ["", "30"] and env ["SECRET=abc"].
        XCTAssertEqual(ProcessDetailsReader.parseArguments(procargs(argc: 2, path: "/bin/sleep", argv: ["", "30"], env: ["SECRET=abc"])), ["", "30"])
        XCTAssertEqual(ProcessDetailsReader.parseArguments(procargs(argc: 1, path: "/bin/sleep", argv: [""], env: ["SECRET=abc"])), [""])
        XCTAssertEqual(ProcessDetailsReader.parseArguments(procargs(argc: 3, path: "/bin/foo", argv: ["foo", "--name", ""], env: ["SECRET=abc"])), ["foo", "--name", ""])
        XCTAssertEqual(ProcessDetailsReader.parseArguments(procargs(argc: 1, path: "/usr/bin/a", argv: ["a"], env: [])), ["a"])
        XCTAssertNil(ProcessDetailsReader.parseArguments(procargs(argc: 3, path: "/bin/foo", argv: ["foo"], env: [])), "truncated")
    }

    func testIdentityNeedsStartTime() {
        XCTAssertTrue(ProcessListModel.same(entry(5, "a", start: 9), entry(5, "b", start: 9)))
        XCTAssertFalse(ProcessListModel.same(entry(5, "a", start: nil), entry(5, "a", start: nil)))
        XCTAssertFalse(ProcessListModel.same(entry(5, "a", start: 9), entry(5, "a", start: 10)))
    }

    func testBundlePathIsOutermostApp() {
        XCTAssertEqual(ProcessDetailsReader.bundlePath(forExecutable: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Helper (GPU).app/Contents/MacOS/Helper (GPU)"),
                       "/Applications/Google Chrome.app")
        XCTAssertNil(ProcessDetailsReader.bundlePath(forExecutable: "/usr/sbin/syslogd"))
    }

    /// Switching filters or opening a confirmation used to widen the popover for a moment because
    /// the hosting view reported SwiftUI's ideal width.
    func testProcessesTabKeepsItsWidth() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MonitorDetailViewController.tabKey)
        defer { saved.map { defaults.set($0, forKey: MonitorDetailViewController.tabKey) } ?? defaults.removeObject(forKey: MonitorDetailViewController.tabKey) }
        defaults.set(1, forKey: MonitorDetailViewController.tabKey)
        let model = ProcessListModel()
        let controller = MonitorDetailViewController(config: MonitorAppearance(), processes: model)
        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()
        let width = controller.view.fittingSize.width
        let long = String(repeating: "Very Long Process Name ", count: 8)
        model.publish([entry(10, long, kind: .app, memory: 1, start: 5), entry(11, "b", kind: .system, memory: 2, start: 6, uid: 0)])
        for filter in ProcessFilter.allCases {
            model.query.filter = filter
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.view.fittingSize.width, width, "\(filter)")
        }
        model.query.filter = .all
        model.confirming = 10
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.view.fittingSize.width, width)
        model.open(model.entries[0])
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.view.fittingSize.width, width)
    }

    /// The user's three reports, on a real popover: the size must depend only on the tab shown,
    /// never on which tab was shown first, and the process list must fill the popover's width.
    func testPopoverSizeFollowsTabOnly() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: MonitorDetailViewController.tabKey)
        defer { saved.map { defaults.set($0, forKey: MonitorDetailViewController.tabKey) } ?? defaults.removeObject(forKey: MonitorDetailViewController.tabKey) }
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let model = ProcessListModel()
        var rows = [ProcessEntry]()
        for index in 1...300 {
            let kind: ProcessKind = index % 3 == 0 ? .app : .background
            rows.append(entry(pid_t(index), "Process number \(index) with a fairly long name", kind: kind, memory: UInt64(index), start: UInt64(index)))
        }
        model.publish(rows)

        func open(processes: Bool) -> (NSPopover, MonitorDetailViewController) {
            defaults.set(processes ? 1 : 0, forKey: MonitorDetailViewController.tabKey)
            let controller = MonitorDetailViewController(config: MonitorAppearance(), processes: model)
            let popover = NSPopover()
            popover.animates = false
            popover.contentViewController = controller
            controller.popover = popover
            popover.show(relativeTo: window.contentView!.bounds, of: window.contentView!, preferredEdge: .minY)
            settle()
            XCTAssertTrue(popover.isShown, "the popover must really be on screen for this test to mean anything")
            return (popover, controller)
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        func check(_ popover: NSPopover, _ controller: MonitorDetailViewController, _ expected: NSSize, _ label: String) {
            XCTAssertEqual(popover.contentSize, expected, label)
            XCTAssertEqual(controller.view.frame.size, expected, label)
            if controller.isShowingProcesses {
                let frame = controller.processesFrame
                XCTAssertLessThanOrEqual(frame.maxX, expected.width, label)
                XCTAssertGreaterThan(frame.width, expected.width - 40, label)
            }
        }

        var (popover, controller) = open(processes: false)
        let summary = popover.contentSize
        controller.selectTab(processes: true); settle()
        let processes = popover.contentSize
        XCTAssertGreaterThan(processes.width, summary.width)
        check(popover, controller, processes, "summary → processes")
        controller.selectTab(processes: false); settle()
        check(popover, controller, summary, "processes → summary")
        controller.selectTab(processes: true); settle()
        check(popover, controller, processes, "summary → processes again")
        model.open(model.entries[0]); settle()
        check(popover, controller, processes, "detail")
        model.closeDetails(); settle()
        check(popover, controller, processes, "back from detail")
        popover.close()

        (popover, controller) = open(processes: true)
        check(popover, controller, processes, "reopened on processes")
        controller.selectTab(processes: false); settle()
        check(popover, controller, summary, "reopened → summary")
        popover.close()
    }
}
