import Cocoa
import Carbon.HIToolbox
import XCTest
@testable import Nexo

final class SnapGeometryTests: XCTestCase {
    private let area = CGRect(x: 0, y: 25, width: 1800, height: 1100)
    private let window = CGRect(x: 100, y: 100, width: 600, height: 400)

    func testHalvesThirdsQuarters() {
        XCTAssertEqual(SnapGeometry.frame(.leftHalf, window: window, area: area), CGRect(x: 0, y: 25, width: 900, height: 1100))
        XCTAssertEqual(SnapGeometry.frame(.bottomHalf, window: window, area: area), CGRect(x: 0, y: 575, width: 1800, height: 550))
        XCTAssertEqual(SnapGeometry.frame(.lastTwoThirds, window: window, area: area), CGRect(x: 600, y: 25, width: 1200, height: 1100))
        XCTAssertEqual(SnapGeometry.frame(.topRight, window: window, area: area), CGRect(x: 900, y: 25, width: 900, height: 550))
        XCTAssertEqual(SnapGeometry.frame(.maximize, window: window, area: area), area)
    }

    func testThirdsFollowPortraitScreens() {
        let portrait = CGRect(x: 0, y: 0, width: 1000, height: 1800)
        XCTAssertEqual(SnapGeometry.frame(.firstThird, window: window, area: portrait), CGRect(x: 0, y: 0, width: 1000, height: 600))
    }

    func testCenterKeepsSizeAndClampsToArea() {
        XCTAssertEqual(SnapGeometry.frame(.center, window: window, area: area), CGRect(x: 600, y: 375, width: 600, height: 400))
        let huge = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        XCTAssertEqual(SnapGeometry.frame(.center, window: huge, area: area), area)
    }

    func testGapsAreFullOnOuterEdgesAndHalfBetweenWindows() {
        let left = SnapGeometry.frame(.leftHalf, window: window, area: area, gap: 10)
        let right = SnapGeometry.frame(.rightHalf, window: window, area: area, gap: 10)
        XCTAssertEqual(left, CGRect(x: 10, y: 35, width: 885, height: 1080))
        XCTAssertEqual(right.minX - left.maxX, 10, accuracy: 0.001)
    }

    func testMoveToOtherDisplayScalesAndStaysInside() {
        let moved = SnapGeometry.move(window, from: area, to: CGRect(x: 1800, y: 0, width: 900, height: 550))
        XCTAssertEqual(moved, CGRect(x: 1850, y: 37.5, width: 300, height: 200))
    }

    func testDragTargets() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1125)
        XCTAssertEqual(SnapGeometry.dragTarget(CGPoint(x: 1, y: 600), area: screen), .leftHalf)
        XCTAssertEqual(SnapGeometry.dragTarget(CGPoint(x: 1, y: 10), area: screen), .topLeft)
        XCTAssertEqual(SnapGeometry.dragTarget(CGPoint(x: 900, y: 1), area: screen), .maximize)
        XCTAssertEqual(SnapGeometry.dragTarget(CGPoint(x: 1799, y: 1120), area: screen), .bottomRight)
        XCTAssertNil(SnapGeometry.dragTarget(CGPoint(x: 900, y: 600), area: screen))
    }
}

struct FixedSysctl: SysctlReading {
    let values: [String: Int32]
    func int32(_ name: String) -> Int32? { values[name] }
}

final class MonitorTests: XCTestCase {
    func testPressurePercentIsInverseOfFreeLevel() {
        let pressure = MemoryPressure.read(FixedSysctl(values: ["kern.memorystatus_vm_pressure_level": 1, "kern.memorystatus_level": 84]))
        XCTAssertEqual(pressure.level, .normal)
        XCTAssertEqual(pressure.percent, 16)
    }

    func testPressureLevelsMapToColorsIndependentlyOfPercent() {
        let warning = MemoryPressure.read(FixedSysctl(values: ["kern.memorystatus_vm_pressure_level": 2, "kern.memorystatus_level": 90]))
        let critical = MemoryPressure.read(FixedSysctl(values: ["kern.memorystatus_vm_pressure_level": 4, "kern.memorystatus_level": 90]))
        let normalButFull = MemoryPressure.read(FixedSysctl(values: ["kern.memorystatus_vm_pressure_level": 1, "kern.memorystatus_level": 2]))
        var sample = MonitorSample()
        sample.pressure = warning
        XCTAssertEqual(MonitorWidgetView.color(.memory, sample), .systemYellow)
        sample.pressure = critical
        XCTAssertEqual(MonitorWidgetView.color(.memory, sample), .systemRed)
        sample.pressure = normalButFull
        XCTAssertEqual(MonitorWidgetView.color(.memory, sample), .systemGreen, "color follows the level, never the percentage")
        XCTAssertEqual(normalButFull.percent, 98)
    }

    func testMissingSysctlsFallBackToNormalUnknown() {
        let pressure = MemoryPressure.read(FixedSysctl(values: [:]))
        XCTAssertEqual(pressure.level, .normal)
        XCTAssertNil(pressure.percent)
    }

    func testCPUUsageFromTickDeltas() {
        // one core: user, system, idle, nice
        let usage = CPUReader.usage(previous: [100, 50, 800, 0], current: [130, 60, 860, 0])
        XCTAssertEqual(usage, 40.0 / 100.0, accuracy: 0.0001)
    }

    func testCPULoadBreakdownAndPerCore() {
        // two cores: user, system, idle, nice
        let load = CPUReader.load(previous: [0, 0, 0, 0, 0, 0, 0, 0], current: [30, 10, 60, 0, 0, 0, 100, 0])
        XCTAssertEqual(load.perCore, [0.4, 0])
        XCTAssertEqual(load.total, 0.2, accuracy: 0.0001)
        XCTAssertEqual(load.user, 0.15, accuracy: 0.0001)
        XCTAssertEqual(load.system, 0.05, accuracy: 0.0001)
        XCTAssertEqual(load.idle, 0.8, accuracy: 0.0001)
    }

    func testCPULoadSurvivesCounterWrapAndIdleTicks() {
        let wrapped = CPUReader.load(previous: [UInt64(UInt32.max) - 9, 0, 0, 0], current: [10, 0, 0, 0])
        XCTAssertEqual(wrapped.total, 1, accuracy: 0.0001, "32-bit rollover counts as 20 user ticks, no trap")
        let none = CPUReader.load(previous: [5, 5, 5, 5], current: [5, 5, 5, 5])
        XCTAssertEqual(none.total, 0)
        XCTAssertEqual(none.perCore, [0])
    }

    func testRateFormatting() {
        XCTAssertEqual(MonitorFormat.rate(512), "512B/s")
        XCTAssertEqual(MonitorFormat.rate(2_500), "2.5KB/s")
        XCTAssertEqual(MonitorFormat.rate(25_000_000), "25MB/s")
    }
}

final class SimulatorParsingTests: XCTestCase {
    func testSimctlJSON() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-1": [
            {"udid": "A", "name": "iPhone 17", "state": "Booted", "isAvailable": true},
            {"udid": "B", "name": "iPhone Air", "state": "Shutdown", "isAvailable": true},
            {"udid": "C", "name": "Broken", "state": "Shutdown", "isAvailable": false}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
            {"udid": "D", "name": "Watch", "state": "Shutdown"}
          ]
        }}
        """
        let devices = IOSDeviceService.parse(Data(json.utf8))
        XCTAssertEqual(Set(devices.map(\.id)), ["A", "B", "D"])
        XCTAssertEqual(devices.first { $0.id == "A" }?.isBooted, true)
        XCTAssertEqual(devices.first { $0.id == "A" }?.runtime, "iOS 26.1")
        XCTAssertEqual(devices.first { $0.id == "D" }?.runtime, "watchOS 11.0")
    }

    func testAvdListIgnoresInfoLines() {
        XCTAssertEqual(AndroidDeviceService.parseAvds("INFO    | Storing crashdata\nPixel_4a\n\nMedium_Phone_API_36.0\n"),
                       ["Pixel_4a", "Medium_Phone_API_36.0"])
    }

    func testBadJSONYieldsNothing() {
        XCTAssertTrue(IOSDeviceService.parse(Data("nope".utf8)).isEmpty)
    }
}

final class ExtrasTests: XCTestCase {
    func testLsofParsingDedupesAddressFamilies() {
        let ports = PortScanner.parse("p10\ncnode\nn*:3000\nn[::1]:3000\np11\ncpostgres\nn127.0.0.1:5432\n")
        XCTAssertEqual(ports.map(\.port), [3000, 5432])
        XCTAssertEqual(ports.first?.command, "node")
        XCTAssertEqual(ports.first?.pid, 10)
    }

    func testClipboardSkipsSecrets() {
        XCTAssertTrue(ClipboardWatcher.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], sourceApp: nil, excluded: []))
        XCTAssertTrue(ClipboardWatcher.shouldSkip(types: ["public.utf8-plain-text"], sourceApp: "com.bitwarden.desktop", excluded: ClipboardWatcher.defaultExcludedApps))
        XCTAssertFalse(ClipboardWatcher.shouldSkip(types: ["public.utf8-plain-text"], sourceApp: "com.apple.Terminal", excluded: ClipboardWatcher.defaultExcludedApps))
    }

    func testClipboardHistoryDedupesLimitsAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nexo-clip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = ClipboardHistory(fileURL: url)
        history.add("a", sourceApp: nil)
        history.add("b", sourceApp: nil)
        history.add("a", sourceApp: nil)
        history.add("   ", sourceApp: nil)
        history.add(String(repeating: "x", count: ClipboardHistory.maxEntryLength + 1), sourceApp: nil)
        XCTAssertEqual(history.entries.map(\.text), ["a", "b"])
        XCTAssertEqual(ClipboardHistory(fileURL: url).entries.map(\.text), ["a", "b"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        (0..<(ClipboardHistory.limit + 5)).forEach { history.add("item \($0)", sourceApp: nil) }
        XCTAssertEqual(history.entries.count, ClipboardHistory.limit)
    }

    func testQuitDecision() {
        let q = Int64(kVK_ANSI_Q)
        func decide(_ type: CGEventType, _ flags: CGEventFlags, repeating: Bool = false, held: Bool = false, excluded: Bool = false) -> QuitKeyDecision {
            QuitKeyDecision.decide(type: type, keyCode: q, flags: flags, isAutorepeat: repeating, qHeld: held, excluded: excluded)
        }
        XCTAssertEqual(decide(.keyDown, .maskCommand), .startCountdown)
        XCTAssertEqual(decide(.keyDown, .maskCommand, repeating: true, held: true), .swallow)
        XCTAssertEqual(decide(.keyDown, []), .pass)
        XCTAssertEqual(decide(.keyDown, [.maskCommand, .maskShift]), .pass)
        XCTAssertEqual(decide(.keyDown, .maskCommand, excluded: true), .pass)
        XCTAssertEqual(decide(.keyUp, []), .pass)
        XCTAssertEqual(decide(.keyUp, .maskCommand, held: true), .release(swallow: true))
        XCTAssertEqual(QuitKeyDecision.decide(type: .flagsChanged, keyCode: 55, flags: [], isAutorepeat: false, qHeld: true, excluded: false), .release(swallow: false))
    }

    func testLimiterNeverExceedsFullScale() {
        XCTAssertEqual(MixRender.limit(0.5), 0.5)
        XCTAssertLessThanOrEqual(abs(MixRender.limit(1.5)), 1)
        XCTAssertLessThanOrEqual(abs(MixRender.limit(-40)), 1)
        XCTAssertLessThan(MixRender.limit(0.95), MixRender.limit(1.2))
    }

    func testHelperProcessesGroupWithTheirApp() {
        XCTAssertEqual(AudioSystem.familyID("com.microsoft.edgemac.helper"), "com.microsoft.edgemac")
        XCTAssertEqual(AudioSystem.familyID("com.google.Chrome.helper.Renderer"), "com.google.Chrome")
        XCTAssertEqual(AudioSystem.familyID("com.spotify.client"), "com.spotify.client")
    }
}

final class ThemeTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nexo-themes-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "nexo.tests.themes")
        defaults.removePersistentDomain(forName: "nexo.tests.themes")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStockThemeEncodesToEmptyObject() throws {
        XCTAssertEqual(String(data: try JSONEncoder().encode(SwitcherTheme.stock), encoding: .utf8), "{}")
    }

    func testSaveLoadRenameDeleteAndReservedNames() {
        let store = ThemeStore(directory: directory, defaults: defaults)
        var theme = SwitcherTheme.glass
        theme.panelCornerRadius = 30
        XCTAssertTrue(store.save(theme, as: "Mine"))
        XCTAssertFalse(store.save(theme, as: "Glass"), "built-in names are read-only")
        XCTAssertEqual(store.preset(named: "Mine"), theme)
        XCTAssertTrue(store.rename("Mine", to: "Night"))
        XCTAssertNil(store.preset(named: "Mine"))
        XCTAssertEqual(store.preset(named: "Night"), theme)
        store.delete("Night")
        XCTAssertEqual(store.userPresetNames, [])
        store.delete("Glass")
        XCTAssertNotNil(store.preset(named: "Glass"))
    }

    func testActiveThemePersistsAndExportImportRoundtrips() throws {
        let store = ThemeStore(directory: directory, defaults: defaults)
        store.setActive(.compact, name: "Compact")
        XCTAssertEqual(ThemeStore(directory: directory, defaults: defaults).active, .compact)
        XCTAssertEqual(store.activeName, "Compact")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("export.json")
        try store.write(.glass, to: file)
        XCTAssertEqual(try store.load(file), .glass)
    }

    func testNamesCannotEscapeTheDirectory() {
        XCTAssertFalse(ThemeStore.sanitize("../../etc/passwd").contains("/"))
        XCTAssertFalse(ThemeStore.sanitize("..").hasPrefix("."))
    }

    func testHexColors() {
        XCTAssertEqual(NSColor(hex: "#FF8000CC")?.hexString, "#FF8000CC")
        XCTAssertEqual(NSColor(hex: "#00FF00")?.hexString, "#00FF00FF")
        XCTAssertNil(NSColor(hex: "red"))
        XCTAssertNil(NSColor(hex: nil))
    }
}

final class MonitorAppearanceTests: XCTestCase {
    func testOldOrPartialJSONDecodesWithDefaults() throws {
        let json = #"{"spacing": 6, "styles": {"cpu": {"enabled": true, "label": "PROC"}}}"#
        let appearance = try JSONDecoder().decode(MonitorAppearance.self, from: Data(json.utf8))
        XCTAssertEqual(appearance.spacing, 6)
        XCTAssertEqual(appearance.label(.cpu), "PROC")
        XCTAssertEqual(appearance.style(.cpu).kind, .text)
        XCTAssertEqual(appearance.popover.width, 300)
        XCTAssertEqual(appearance.orderedMetrics, Metric.allCases)
    }

    func testOrderKeepsUnknownIdsOutAndAppendsNewMetrics() {
        var appearance = MonitorAppearance()
        appearance.order = ["memory", "bogus", "cpu"]
        XCTAssertEqual(Array(appearance.orderedMetrics.prefix(2)), [.memory, .cpu])
        XCTAssertEqual(appearance.orderedMetrics.count, Metric.allCases.count)
    }

    func testPresetsRoundTripThroughStore() throws {
        let defaults = UserDefaults(suiteName: "nexo.tests.monitorAppearance")!
        defaults.removePersistentDomain(forName: "nexo.tests.monitorAppearance")
        let store = MonitorAppearanceStore(defaults: defaults)
        store.appearance = .graphs
        let exported = try store.export()
        XCTAssertEqual(MonitorAppearanceStore(defaults: defaults).appearance, .graphs, "persisted")
        store.appearance = .minimal
        try store.importData(exported)
        XCTAssertEqual(store.appearance, .graphs)
    }

    func testInvalidImportIsSanitizedNotFatal() throws {
        let json = #"{"order": ["cpu", "cpu", "nope", "memory"], "spacing": -50, "styles": {"cpu": {"chartHistory": -1, "warning": 2, "critical": 0.5, "kind": "hologram", "extraWidth": 1e9}}, "popover": {"topProcesses": -3}}"#
        let a = try JSONDecoder().decode(MonitorAppearance.self, from: Data(json.utf8))
        XCTAssertEqual(Array(a.orderedMetrics.prefix(2)), [.cpu, .memory])
        XCTAssertEqual(Set(a.orderedMetrics).count, a.orderedMetrics.count, "no duplicates")
        XCTAssertEqual(a.spacing, 0)
        XCTAssertEqual(a.style(.cpu).chartHistory, 10)
        XCTAssertEqual(a.style(.cpu).kind, .text, "unknown enum falls back instead of failing the whole decode")
        XCTAssertLessThanOrEqual(a.style(.cpu).warning, a.style(.cpu).critical)
        XCTAssertEqual(a.style(.cpu).extraWidth, 20)
        XCTAssertEqual(a.popover.topProcesses, 0)
    }

    func testPresetKeepsAlertsColorsAndLabels() {
        var mine = MonitorAppearance()
        mine.alerts.lowDisk = true
        mine.popover.appColor = "#123456"
        mine.update(.cpu) { $0.label = "PROC" }
        let applied = mine.applying(preset: .minimal)
        XCTAssertTrue(applied.alerts.lowDisk)
        XCTAssertEqual(applied.popover.appColor, "#123456")
        XCTAssertEqual(applied.label(.cpu), "PROC")
        XCTAssertEqual(applied.style(.cpu).colorMode, .monochrome, "the preset's style still applies")
    }

    func testMigratesLegacyKeys() {
        let defaults = UserDefaults(suiteName: "nexo.tests.monitorLegacy")!
        defaults.removePersistentDomain(forName: "nexo.tests.monitorLegacy")
        defaults.set(["network", "cpu"], forKey: "monitor.metrics")
        defaults.set(["network", "gpu", "cpu", "memory"], forKey: "monitor.order")
        defaults.set(1, forKey: "monitor.style")
        let appearance = MonitorAppearanceStore(defaults: defaults).appearance
        XCTAssertEqual(appearance.menuBarMetrics, [.network, .cpu])
        XCTAssertEqual(appearance.style(.cpu).kind, .bar)
    }

    func testMemoryColorStaysOnPressureLevelUnlessOverridden() {
        var appearance = MonitorAppearance()
        var sample = MonitorSample()
        sample.pressure = MemoryPressure(level: .warning, percent: 5)
        XCTAssertEqual(appearance.color(.memory, sample), .systemYellow)
        appearance.update(.memory) { $0.colorMode = .custom; $0.customColor = "#FF0000" }
        XCTAssertEqual(appearance.color(.memory, sample).hexString, "#FF0000FF")
    }

    func testCustomThresholds() {
        var appearance = MonitorAppearance()
        appearance.update(.cpu) { $0.warning = 0.5; $0.critical = 0.6 }
        var sample = MonitorSample()
        sample.cpuLoad = CPULoad(total: 0.55, user: 0.5, system: 0.05, idle: 0.45, perCore: [])
        XCTAssertEqual(appearance.color(.cpu, sample), .systemOrange)
        sample.cpuLoad?.total = 0.65
        XCTAssertEqual(appearance.color(.cpu, sample), .systemRed)
    }
}

final class MonitorExtrasTests: XCTestCase {
    func testParsesPsOutputWithSpacesInNames() {
        let output = "  123  12.5  2048 Google Chrome Helper\n 9 0,3 10 launchd\ngarbage\n"
        let processes = TopProcessesReader.parse(output)
        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0], ProcessUsage(pid: 123, name: "Google Chrome Helper", cpu: 12.5, memory: 2048 * 1024))
        XCTAssertEqual(processes[1].cpu, 0.3, accuracy: 0.001)
    }

    func testAlertsFireOncePerEpisode() {
        var posted = [String]()
        var now = Date(timeIntervalSince1970: 0)
        let alerter = MonitorAlerter(now: { now }, post: { title, _ in posted.append(title) })
        var alerts = MonitorAlerts()
        alerts.memoryPressure = true
        alerts.cpuSustained = true
        alerts.cpuThreshold = 0.8
        alerts.cpuSeconds = 30
        var sample = MonitorSample()
        sample.pressure = MemoryPressure(level: .warning, percent: 40)
        alerter.evaluate(sample, alerts)
        alerter.evaluate(sample, alerts)
        XCTAssertEqual(posted, ["Memory pressure warning"])
        sample.pressure = MemoryPressure(level: .critical, percent: 80)
        alerter.evaluate(sample, alerts)
        XCTAssertEqual(posted.last, "Memory pressure critical")

        posted.removeAll()
        sample.pressure = MemoryPressure(level: .normal, percent: 10)
        sample.cpuLoad = CPULoad(total: 0.9, user: 0.9, system: 0, idle: 0.1, perCore: [])
        alerter.evaluate(sample, alerts)
        now = now.addingTimeInterval(29)
        alerter.evaluate(sample, alerts)
        XCTAssertTrue(posted.isEmpty)
        now = now.addingTimeInterval(2)
        alerter.evaluate(sample, alerts)
        alerter.evaluate(sample, alerts)
        XCTAssertEqual(posted, ["High CPU usage"])
        sample.cpuLoad = CPULoad(total: 0.1, user: 0.1, system: 0, idle: 0.9, perCore: [])
        alerter.evaluate(sample, alerts)
        sample.cpuLoad = CPULoad(total: 0.95, user: 0.95, system: 0, idle: 0.05, perCore: [])
        alerter.evaluate(sample, alerts)
        now = now.addingTimeInterval(31)
        alerter.evaluate(sample, alerts)
        XCTAssertEqual(posted, ["High CPU usage", "High CPU usage"], "re-armed after dropping below the threshold")
    }

    func testLowDiskAlertHasHysteresis() {
        var posted = 0
        let alerter = MonitorAlerter(post: { _, _ in posted += 1 })
        var alerts = MonitorAlerts()
        alerts.lowDisk = true
        alerts.lowDiskFraction = 0.1
        var sample = MonitorSample()
        sample.diskFree = (free: 9, total: 100)
        alerter.evaluate(sample, alerts)
        sample.diskFree = (free: 11, total: 100)
        alerter.evaluate(sample, alerts)
        sample.diskFree = (free: 9, total: 100)
        alerter.evaluate(sample, alerts)
        XCTAssertEqual(posted, 1, "hovering around the threshold doesn't re-notify")
        sample.diskFree = (free: 20, total: 100)
        alerter.evaluate(sample, alerts)
        sample.diskFree = (free: 5, total: 100)
        alerter.evaluate(sample, alerts)
        XCTAssertEqual(posted, 2)
        sample.diskFree = (free: 0, total: 0)
        alerter.evaluate(sample, alerts)
        XCTAssertEqual(posted, 2)
    }
}
