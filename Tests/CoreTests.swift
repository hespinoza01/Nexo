import Cocoa
import XCTest
@testable import Nexo

final class FakeModule: NexoModule {
    static let id = "fake"
    let title = "Fake"
    let icon = "star"
    var enabledByDefault = true
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { isRunning = true; startCount += 1 }
    func stop() { isRunning = false; stopCount += 1 }
    func settingsView() -> NSView { NSView() }
}

final class ModuleRegistryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "nexo.tests.registry")
        defaults.removePersistentDomain(forName: "nexo.tests.registry")
    }

    func testEnabledByDefaultStartsOnLaunch() {
        let registry = ModuleRegistry(defaults: defaults)
        let module = FakeModule()
        registry.register(module)
        registry.startEnabledModules()
        XCTAssertTrue(module.isRunning)
    }

    func testDisabledByDefaultDoesNotStart() {
        let registry = ModuleRegistry(defaults: defaults)
        let module = FakeModule()
        module.enabledByDefault = false
        registry.register(module)
        registry.startEnabledModules()
        XCTAssertFalse(module.isRunning)
        XCTAssertFalse(registry.isEnabled(module))
    }

    func testSetEnabledStopsAndStartsAndPersists() {
        let registry = ModuleRegistry(defaults: defaults)
        let module = FakeModule()
        registry.register(module)
        registry.startEnabledModules()
        registry.setEnabled(false, for: module)
        XCTAssertFalse(module.isRunning)
        XCTAssertEqual(module.stopCount, 1)
        XCTAssertFalse(ModuleRegistry(defaults: defaults).isEnabled(module), "state persists across registries")
        registry.setEnabled(true, for: module)
        XCTAssertTrue(module.isRunning)
        XCTAssertEqual(module.startCount, 2)
    }

    func testRegisterIgnoresDuplicates() {
        let registry = ModuleRegistry(defaults: defaults)
        registry.register(FakeModule())
        registry.register(FakeModule())
        XCTAssertEqual(registry.modules.count, 1)
    }
}

final class FakePowerAssertions: PowerAssertionProvider {
    var created = [(type: String, id: IOPMAssertionID)]()
    var released = [IOPMAssertionID]()
    var fail = false
    private var next: IOPMAssertionID = 1

    func create(_ type: String, reason: String) -> IOPMAssertionID? {
        guard !fail else { return nil }
        defer { next += 1 }
        created.append((type, next))
        return next
    }

    func release(_ id: IOPMAssertionID) { released.append(id) }

    var activityDeclarations = 0
    func declareUserActivity(reason: String) -> IOPMAssertionID? {
        activityDeclarations += 1
        return 99
    }
}

final class KeepAwakeControllerTests: XCTestCase {
    func testIndefiniteHasNoRemainingAndReleasesOnDeactivate() {
        let power = FakePowerAssertions()
        let controller = KeepAwakeController(provider: power)
        XCTAssertTrue(controller.activate(.indefinitely, keepDisplayAwake: false))
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.remaining)
        XCTAssertEqual(power.created.first?.type, kIOPMAssertionTypePreventUserIdleSystemSleep as String)
        controller.deactivate()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(power.released, [1])
    }

    func testDisplayOptionUsesDisplayAssertion() {
        let power = FakePowerAssertions()
        KeepAwakeController(provider: power).activate(.hour1, keepDisplayAwake: true)
        XCTAssertEqual(power.created.map(\.type), [kIOPMAssertionTypePreventUserIdleSystemSleep as String,
                                                     kIOPMAssertionTypePreventUserIdleDisplaySleep as String])
    }

    func testDisplayToggleKeepsSessionAndTimer() {
        let power = FakePowerAssertions()
        let controller = KeepAwakeController(provider: power)
        controller.activate(.hour1, keepDisplayAwake: false)
        let end = controller.endDate
        controller.setKeepDisplayAwake(true)
        XCTAssertEqual(power.created.count, 2)
        XCTAssertEqual(controller.endDate, end)
        controller.setKeepDisplayAwake(false)
        XCTAssertEqual(power.released, [2])
        XCTAssertTrue(controller.isActive)
    }

    func testPauseReleasesAndResumeReacquires() {
        let power = FakePowerAssertions()
        let controller = KeepAwakeController(provider: power)
        controller.activate(.indefinitely, keepDisplayAwake: true)
        controller.pause()
        XCTAssertEqual(power.released, [1, 2])
        XCTAssertTrue(controller.isActive)
        controller.resume()
        XCTAssertEqual(power.created.count, 4)
        controller.deactivate()
        XCTAssertEqual(power.released, [1, 2, 3, 4])
    }

    func testFailedResumeEndsSession() {
        let power = FakePowerAssertions()
        let controller = KeepAwakeController(provider: power)
        controller.activate(.indefinitely, keepDisplayAwake: false)
        controller.pause()
        controller.pause()
        power.fail = true
        controller.resume()
        XCTAssertFalse(controller.isActive)
        controller.resume()
        XCTAssertFalse(controller.isPaused)
    }

    func testDisplayToggleWhilePausedCreatesNothing() {
        let power = FakePowerAssertions()
        let controller = KeepAwakeController(provider: power)
        controller.activate(.indefinitely, keepDisplayAwake: false)
        controller.pause()
        controller.setKeepDisplayAwake(true)
        XCTAssertEqual(power.created.count, 1)
        controller.resume()
        XCTAssertEqual(power.created.count, 3)
    }

    func testResumeWithRemainingInterval() {
        let power = FakePowerAssertions()
        let now = Date(timeIntervalSince1970: 1000)
        let controller = KeepAwakeController(provider: power, now: { now })
        XCTAssertTrue(controller.activate(for: 600, keepDisplayAwake: true))
        XCTAssertEqual(controller.endDate, now.addingTimeInterval(600))
        XCTAssertTrue(controller.activate(for: nil, keepDisplayAwake: true))
        XCTAssertNil(controller.endDate)
        controller.deactivate()
    }

    func testActivityDeclarationOnlyWhileActive() {
        let power = FakePowerAssertions()
        let controller = KeepAwakeController(provider: power)
        controller.declareActivity()
        XCTAssertEqual(power.activityDeclarations, 0)
        controller.activate(.indefinitely, keepDisplayAwake: false, activityEvery: 5)
        XCTAssertEqual(power.activityDeclarations, 1)
        XCTAssertTrue(power.released.contains(99))
        controller.deactivate()
    }

    func testTimedExpiryReleasesAssertion() {
        let power = FakePowerAssertions()
        var now = Date(timeIntervalSince1970: 1000)
        let controller = KeepAwakeController(provider: power, now: { now })
        controller.activate(.minutes30, keepDisplayAwake: false)
        XCTAssertEqual(controller.remaining ?? -1, 1800, accuracy: 0.1)
        now = now.addingTimeInterval(1799)
        controller.expireIfDue()
        XCTAssertTrue(controller.isActive)
        now = now.addingTimeInterval(2)
        controller.expireIfDue()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(power.released, [1])
    }

    func testReactivationReleasesPreviousAssertion() {
        let power = FakePowerAssertions()
        let controller = KeepAwakeController(provider: power)
        controller.activate(.hour1, keepDisplayAwake: false)
        controller.activate(.hours2, keepDisplayAwake: true)
        XCTAssertEqual(power.released, [1])
        XCTAssertEqual(power.created.count, 3)
    }

    func testFailedAssertionStaysInactive() {
        let power = FakePowerAssertions()
        power.fail = true
        let controller = KeepAwakeController(provider: power)
        XCTAssertFalse(controller.activate(.hour1, keepDisplayAwake: false))
        XCTAssertFalse(controller.isActive)
    }
}

final class AppRuleStoreTests: XCTestCase {
    func testRulesAndFallback() {
        let defaults = UserDefaults(suiteName: "nexo.tests.rules")!
        defaults.removePersistentDomain(forName: "nexo.tests.rules")
        let store = AppRuleStore(defaults: defaults)
        XCTAssertNil(store.sourceId(for: "com.apple.Terminal"))
        store.setRule("abc", for: "com.apple.Terminal")
        store.fallbackSourceId = "latam"
        XCTAssertEqual(store.sourceId(for: "com.apple.Terminal"), "abc")
        XCTAssertEqual(store.sourceId(for: "com.other"), "latam")
        XCTAssertEqual(store.sourceId(for: nil), "latam")
        store.setRule(nil, for: "com.apple.Terminal")
        XCTAssertEqual(store.sourceId(for: "com.apple.Terminal"), "latam")
        XCTAssertEqual(AppRuleStore(defaults: defaults).fallbackSourceId, "latam")
    }
}
