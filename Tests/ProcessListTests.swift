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
        XCTAssertEqual(ProcessListReader.executableName(getpid()).map { !$0.isEmpty }, true)
    }

    func testAdminScriptCompiles() throws {
        let arguments = ProcessTerminator.adminArguments(pid: 42, mode: .quit, started: "Tue Nov 17 06:47:46 2026")
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nexo-kill-\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = Shell.run("/usr/bin/osacompile", ["-o", output.path] + arguments.dropLast(3), timeout: 20)
        XCTAssertEqual(result?.status, 0)
    }
}
