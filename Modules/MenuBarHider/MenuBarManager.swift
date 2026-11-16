import Cocoa
import Combine

/// State behind the menu bar page: icons on screen, each app's section, temporary reveal and reorder.
final class MenuBarManager: ObservableObject {
    enum Key {
        static let revealUntil = "menuBar.revealUntil"
        static let revealSeconds = "menuBar.revealSeconds"
        static let revealShortcut = "menuBar.revealShortcut"
    }

    static let revealChoices = [5, 10, 15, 30, 60]

    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var states: [String: Bool] = [:]
    @Published private(set) var hasAccess = false
    @Published private(set) var isScanning = false
    @Published private(set) var isMoving = false
    @Published private(set) var revealedUntil: Date?
    @Published var lastError: String?
    /// Only a running module changes the list: with the module off nothing would ever restore it.
    @Published private(set) var isActive = false

    let controller: AllowStateController
    let system = SystemSectionController()
    private let store: ControlCenterAllowList
    private var hideTimer: Timer?
    private var launchObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "nexo.menubar", qos: .userInitiated)

    init(store: ControlCenterAllowList = .shared) {
        self.store = store
        controller = AllowStateController(store: store)
    }

    var revealSeconds: Int {
        get { Self.revealChoices.contains(UserDefaults.standard.integer(forKey: Key.revealSeconds)) ? UserDefaults.standard.integer(forKey: Key.revealSeconds) : 15 }
        set { UserDefaults.standard.set(newValue, forKey: Key.revealSeconds); objectWillChange.send() }
    }

    /// Something can be revealed now: hidden apps need Full Disk Access, macOS's own icons do not.
    var canReveal: Bool {
        controller.sections.contains { $0.value == .hidden && (hasAccess || SystemSectionController.moduleID($0.key) != nil) }
    }

    var isRevealed: Bool { (revealedUntil ?? .distantPast) > Date() }

    func start() {
        isActive = true
        // A reveal still running when Nexo quit (or crashed) resumes for its remaining time; an expired one re-hides.
        let until = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Key.revealUntil))
        if until > Date() { scheduleHide(at: until) } else { revealedUntil = nil }
        applyNow()
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            // An app gets its switch only once it creates its first icon; try a few times.
            for delay in [1.0, 3.0, 8.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.applyNow() } }
        }
    }

    func stop(restore: Bool) {
        isActive = false
        hideTimer?.invalidate()
        hideTimer = nil
        launchObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        launchObserver = nil
        guard restore else { return }
        UserDefaults.standard.removeObject(forKey: Key.revealUntil)
        system.restoreAll()
        perform(force: true) { try $0.controller.restoreAll() }
    }

    func refresh() {
        hasAccess = store.isReadable
        states = (try? controller.states()) ?? [:]
        guard !isScanning else { return }
        isScanning = true
        queue.async { [weak self] in
            let items = MenuBarItemScanner.scan()
            DispatchQueue.main.async {
                self?.items = items
                self?.isScanning = false
            }
        }
    }

    func setSection(_ section: MenuBarSection, for id: String) {
        let revealed = isRevealed
        if SystemSectionController.moduleID(id) != nil {
            guard isActive else { lastError = L("Turn the module on to hide icons."); return }
            var all = controller.sections
            all[id] = section
            controller.sections = all
            objectWillChange.send()
            system.apply(sections: all, revealed: revealed)
            refreshAfterSystemChange()
            return
        }
        perform { try $0.controller.setSection(section, for: id, revealed: revealed) }
    }

    /// Turns one of macOS's own icons on or off outside the sections (the switch in System Settings).
    /// Turning it on also takes it out of any hidden section.
    func setSystemModule(_ module: SystemMenuItems.Module, shown: Bool) {
        let key = SystemSectionController.key(module.id)
        if shown, controller.sections[key] != nil {
            var all = controller.sections
            all[key] = nil
            controller.sections = all
            objectWillChange.send()
        }
        SystemMenuItems.setShown(shown, module)
        refreshAfterSystemChange()
    }

    /// Control Center applies a module change within a second.
    private func refreshAfterSystemChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }

    func toggleReveal() {
        isRevealed ? hideNow() : reveal()
    }

    func reveal() {
        guard isActive, controller.sections.values.contains(.hidden) else { return }
        scheduleHide(at: Date().addingTimeInterval(TimeInterval(revealSeconds)))
        applyNow()
    }

    func hideNow() {
        hideTimer?.invalidate()
        revealedUntil = nil
        UserDefaults.standard.removeObject(forKey: Key.revealUntil)
        applyNow()
    }

    /// Turns every app Nexo hid back on and clears all sections.
    func showEverything() {
        hideTimer?.invalidate()
        revealedUntil = nil
        controller.sections = [:]
        UserDefaults.standard.removeObject(forKey: Key.revealUntil)
        system.restoreAll()
        refreshAfterSystemChange()
        perform { try $0.controller.restoreAll() }
    }

    /// Puts an icon where `target` is now (to its left when coming from the right, and vice versa),
    /// then re-reads positions.
    func move(_ item: MenuBarItem, onto target: MenuBarItem) {
        let ordered = items
        guard isActive, !isMoving, item.id != target.id, item.canMove, target.canMove,
              let index = ordered.firstIndex(of: item), let targetIndex = ordered.firstIndex(of: target) else { return }
        let toLeft = targetIndex < index
        isMoving = true
        let neighbour = target
        queue.async { [weak self] in
            // Positions may be stale (an app launched, a reveal ended): re-read and drag only if both still sit where shown.
            let current = MenuBarItemScanner.scan()
            guard current.first(where: { $0.id == item.id })?.frame == item.frame,
                  current.first(where: { $0.id == neighbour.id })?.frame == neighbour.frame,
                  CGEventSource.buttonState(.hidSystemState, button: .left) == false else {
                DispatchQueue.main.async {
                    self?.items = current
                    self?.isMoving = false
                    self?.lastError = L("The menu bar changed. Try again.")
                }
                return
            }
            MenuBarDragger.move(item, past: neighbour, toLeft: toLeft)
            usleep(300_000)
            var items = MenuBarItemScanner.scan()
            if Self.order(of: item, in: items) == Self.order(of: item, in: ordered),
               let fresh = items.first(where: { $0.id == item.id }), let target = items.first(where: { $0.id == neighbour.id }) {
                MenuBarDragger.move(fresh, past: target, toLeft: toLeft)
                usleep(300_000)
                items = MenuBarItemScanner.scan()
            }
            let after = Self.order(of: item, in: items)
            let moved = after != nil && after != Self.order(of: item, in: ordered)
            DispatchQueue.main.async {
                self?.items = items
                self?.isMoving = false
                // A reveal that ended mid-drag could not re-hide apps then.
                if self?.isRevealed == false { self?.applyNow() }
                if !moved { self?.lastError = L("macOS did not move the icon. Try again, or ⌘-drag it in the menu bar.") }
            }
        }
    }

    private static func order(of item: MenuBarItem, in items: [MenuBarItem]) -> Int? {
        items.firstIndex { $0.id == item.id }
    }

    private func scheduleHide(at date: Date) {
        hideTimer?.invalidate()
        revealedUntil = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Key.revealUntil)
        let timer = Timer(timeInterval: max(0, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in self?.hideNow() }
        // Common modes: still fires while the Nexo menu is open.
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func applyNow() {
        let revealed = isRevealed
        // macOS's own icons need no Full Disk Access and move nothing, so they apply even mid-drag.
        if isActive {
            let sections = controller.sections
            let managesSystem = !system.journal.isEmpty || sections.keys.contains { SystemSectionController.moduleID($0) != nil }
            system.apply(sections: sections, revealed: revealed)
            if managesSystem { refreshAfterSystemChange() }
        }
        guard !isMoving else { return }
        perform { try $0.controller.apply(revealed: revealed) }
    }

    /// Runs a write against the allow list and refreshes the page; failures surface as `lastError`.
    private func perform(force: Bool = false, _ action: @escaping (MenuBarManager) throws -> Void) {
        guard isActive || force else {
            lastError = L("Turn the module on to hide icons.")
            return
        }
        guard ControlCenterAllowList.isSupported, store.isReadable else {
            hasAccess = false
            if force && !controller.journal.isEmpty { lastError = L("Nexo could not show the icons it hid: it no longer has Full Disk Access.") }
            return
        }
        do {
            try action(self)
            lastError = nil
        } catch {
            lastError = L("Could not change the menu bar: %@", String(describing: error))
        }
        // MenuBarAgent fades icons in/out in ~250 ms; read positions after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }
}
