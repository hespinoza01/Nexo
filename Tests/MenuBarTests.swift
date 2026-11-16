import XCTest
@testable import Nexo

private final class FakeAllowList: AllowListStore {
    var array: [Any]
    var writes = 0
    init(_ states: [(String, Bool)]) {
        array = states.flatMap { id, allowed -> [Any] in
            let key: [String: Any] = ["bundle": ["_0": id]]
            return [key, ["location": key, "menuItemLocations": [key], "isAllowed": allowed] as [String: Any]]
        }
    }
    func read() throws -> [Any] { array }
    func write(_ array: [Any]) throws { self.array = array; writes += 1 }
    var states: [String: Bool] { TrackedApplications.allowedStates(in: array) }
}

final class MenuBarTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "MenuBarTests")
        defaults.removePersistentDomain(forName: "MenuBarTests")
    }

    func testCodecRoundTripKeepsUnknownFieldsAndOnlyFlipsIsAllowed() throws {
        let other: [String: Any] = ["adhocBinary": ["_0": ["relative": "file:///x"]]]
        let store = FakeAllowList([("a", true), ("b", true)])
        store.array += [other, ["isAllowed": true, "extra": 7] as [String: Any]]
        let data = try TrackedApplications.encode(store.array)
        let decoded = try XCTUnwrap(TrackedApplications.decode(data))
        let result = TrackedApplications.settingAllowed(false, for: ["a"], in: decoded)
        XCTAssertEqual(result.changed, ["a"])
        XCTAssertEqual(TrackedApplications.allowedStates(in: result.array), ["a": false, "b": true])
        XCTAssertEqual((result.array[5] as? [String: Any])?["extra"] as? Int, 7)
        XCTAssertEqual(((result.array[1] as? [String: Any])?["menuItemLocations"] as? [Any])?.count, 1)
    }

    func testHiddenAppsTurnOffAndRevealTurnsThemBackOn() throws {
        let store = FakeAllowList([("a", true), ("b", true), ("c", true)])
        let controller = AllowStateController(store: store, defaults: defaults)
        try controller.setSection(.hidden, for: "a", revealed: false)
        try controller.setSection(.alwaysHidden, for: "b", revealed: false)
        XCTAssertEqual(store.states, ["a": false, "b": false, "c": true])
        XCTAssertEqual(controller.journal, ["a", "b"])
        try controller.apply(revealed: true)
        XCTAssertEqual(store.states, ["a": true, "b": false, "c": true])
        XCTAssertEqual(controller.journal, ["b"])
        try controller.apply(revealed: false)
        XCTAssertEqual(store.states["a"], false)
    }

    func testAppTurnedOffByUserIsLeftAloneUntilMovedToVisible() throws {
        let store = FakeAllowList([("user", false), ("a", true)])
        let controller = AllowStateController(store: store, defaults: defaults)
        try controller.apply(revealed: false)
        try controller.restoreAll()
        XCTAssertEqual(store.states["user"], false)
        XCTAssertEqual(store.writes, 0)
        try controller.setSection(.visible, for: "user", revealed: false)
        XCTAssertEqual(store.states["user"], true)
    }

    func testRestoreAllOnlyTurnsOnWhatNexoHid() throws {
        let store = FakeAllowList([("user", false), ("a", true)])
        let controller = AllowStateController(store: store, defaults: defaults)
        try controller.setSection(.alwaysHidden, for: "a", revealed: false)
        try controller.restoreAll()
        XCTAssertEqual(store.states, ["user": false, "a": true])
        XCTAssertTrue(controller.journal.isEmpty)
    }

    func testNoWriteWhenNothingChanges() throws {
        let store = FakeAllowList([("a", true)])
        let controller = AllowStateController(store: store, defaults: defaults)
        try controller.apply(revealed: false)
        try controller.apply(revealed: true)
        XCTAssertEqual(store.writes, 0)
    }
}

final class SystemMenuItemsTests: XCTestCase {
    func testMenuExtraMapsToModule() {
        XCTAssertEqual(SystemMenuItems.module(forExtra: "wifi")?.id, "WiFi")
        XCTAssertEqual(SystemMenuItems.module(forExtra: "now-playing")?.id, "NowPlaying")
        XCTAssertEqual(SystemMenuItems.module(forExtra: "bluetooth")?.id, "Bluetooth")
        XCTAssertNil(SystemMenuItems.module(forExtra: "clock"))
        XCTAssertNil(SystemMenuItems.module(forExtra: "controlcenter"))
    }

    func testBitsKeepOtherFlags() {
        XCTAssertEqual(SystemMenuItems.updated(18, shown: false), 24)
        XCTAssertEqual(SystemMenuItems.updated(24, shown: true), 18)
        XCTAssertEqual(SystemMenuItems.updated(9, shown: true), 3)
        XCTAssertEqual(SystemMenuItems.updated(nil, shown: false), 8)
        XCTAssertFalse(SystemMenuItems.isShown(value: 9, default: true))
        XCTAssertTrue(SystemMenuItems.isShown(value: 2, default: false))
        XCTAssertTrue(SystemMenuItems.isShown(value: 16, default: true))
    }
}

private final class FakeModules: SystemModuleSwitch {
    var shown: [String: Bool]
    init(_ shown: [String: Bool]) { self.shown = shown }
    func exists(_ id: String) -> Bool { id != "Gone" }
    func isShown(_ id: String) -> Bool { shown[id] ?? true }
    func setShown(_ value: Bool, _ id: String) { shown[id] = value }
}

final class SystemSectionTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "SystemSectionTests")
        defaults.removePersistentDomain(forName: "SystemSectionTests")
    }

    func testHiddenModulesHideAndRevealShowsOnlyTheHiddenSection() {
        let modules = FakeModules(["WiFi": true, "Bluetooth": true, "Sound": true])
        let controller = SystemSectionController(modules: modules, defaults: defaults)
        let sections: [String: MenuBarSection] = ["system:WiFi": .hidden, "system:Bluetooth": .alwaysHidden, "app.id": .hidden]
        controller.apply(sections: sections, revealed: false)
        XCTAssertEqual(modules.shown, ["WiFi": false, "Bluetooth": false, "Sound": true])
        XCTAssertEqual(controller.journal, ["WiFi", "Bluetooth"])
        controller.apply(sections: sections, revealed: true)
        XCTAssertEqual(modules.shown, ["WiFi": true, "Bluetooth": false, "Sound": true])
        controller.apply(sections: sections, revealed: false)
        XCTAssertEqual(modules.shown["WiFi"], false)
    }

    func testLeavingTheSectionsAndRestoreShowWhatNexoHidOnly() {
        let modules = FakeModules(["WiFi": true, "Siri": false])
        let controller = SystemSectionController(modules: modules, defaults: defaults)
        controller.apply(sections: ["system:WiFi": .hidden], revealed: false)
        controller.apply(sections: [:], revealed: false)
        XCTAssertEqual(modules.shown, ["WiFi": true, "Siri": false])
        XCTAssertEqual(controller.journal, [])
        controller.apply(sections: ["system:WiFi": .alwaysHidden], revealed: false)
        controller.restoreAll()
        XCTAssertEqual(modules.shown, ["WiFi": true, "Siri": false])
    }

    func testUnknownModuleIsIgnoredAndAppsSkipSystemKeys() {
        let modules = FakeModules([:])
        let controller = SystemSectionController(modules: modules, defaults: defaults)
        controller.apply(sections: ["system:Gone": .hidden], revealed: false)
        XCTAssertEqual(controller.journal, [])
        let apps = AllowStateController(store: FakeAllowList([("a", true)]), defaults: defaults)
        apps.sections = ["system:WiFi": .hidden, "a": .hidden]
        XCTAssertEqual(apps.desiredOff(revealed: false), ["a"])
    }

    func testModuleOffByUserShowsWhenRevealedOnceNexoManagesIt() {
        let modules = FakeModules(["Siri": false])
        let controller = SystemSectionController(modules: modules, defaults: defaults)
        controller.apply(sections: ["system:Siri": .hidden], revealed: true)
        XCTAssertEqual(modules.shown["Siri"], true)
    }
}
