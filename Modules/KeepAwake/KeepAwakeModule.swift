import Cocoa
import ShortcutRecorder

/// Keep the Mac (and optionally the display) from sleeping, from the menu bar or a global shortcut.
final class KeepAwakeModule: NexoModule {
    static let id = "keepAwake"
    let title = "Keep Awake"
    let icon = "cup.and.saucer"
    private(set) var isRunning = false

    private enum Key {
        static let display = "keepAwake.keepDisplayAwake"
        static let duration = "keepAwake.defaultDuration"
        static let shortcut = "keepAwake.shortcut"
        static let activity = "keepAwake.activityMinutes"
        static let autoStart = "keepAwake.startOnLaunch"
        static let pauseWhenLocked = "keepAwake.pauseWhenLocked"
        /// The running session, kept across quits, restarts and shutdowns until the user turns it off:
        /// its end as seconds since 1970, or 0 for "until turned off". Absent = no session.
        static let session = "keepAwake.session"
    }

    static let activityChoices = [0, 1, 2, 5, 10]
    private static let lockNotification = Notification.Name("com.apple.screenIsLocked")
    private static let unlockNotification = Notification.Name("com.apple.screenIsUnlocked")

    private let controller = KeepAwakeController()
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.toggle() }
    private var observers = [NSObjectProtocol]()
    private var lockObservers = [NSObjectProtocol]()
    private weak var statusLabel: NSTextField?
    private weak var toggleButton: NSButton?

    private var keepDisplayAwake: Bool {
        get { UserDefaults.standard.object(forKey: Key.display) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.display) }
    }

    private var defaultDuration: KeepAwakeController.Duration {
        get { KeepAwakeController.Duration(rawValue: UserDefaults.standard.integer(forKey: Key.duration)) ?? .indefinitely }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.duration) }
    }

    private var activityMinutes: Int {
        get { Self.activityChoices.contains(UserDefaults.standard.integer(forKey: Key.activity)) ? UserDefaults.standard.integer(forKey: Key.activity) : 0 }
        set { UserDefaults.standard.set(newValue, forKey: Key.activity) }
    }

    private var startOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Key.autoStart) }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoStart) }
    }

    private var pauseWhenLocked: Bool {
        get { UserDefaults.standard.bool(forKey: Key.pauseWhenLocked) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.pauseWhenLocked)
            syncLockObservers()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        controller.onChange = { [weak self] in self?.refreshIndicator() }
        hotKey.register(ShortcutStore.load(Key.shortcut))
        // A process that exits releases its assertions anyway; this keeps `pmset` tidy on a normal quit.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                // Quitting doesn't end the session: detach first so the saved session survives.
                self?.controller.onChange = nil
                self?.controller.deactivate()
            })
        syncLockObservers()
        if !restoreSession(), startOnLaunch { activate(defaultDuration) }
    }

    /// Resumes the session that was running when Nexo last quit (or the Mac restarted / shut down).
    private func restoreSession(retry: Bool = true) -> Bool {
        guard let saved = UserDefaults.standard.object(forKey: Key.session) as? Double else { return false }
        let interval: TimeInterval? = saved == 0 ? nil : Date(timeIntervalSince1970: saved).timeIntervalSinceNow
        if let interval, interval <= 0 {
            UserDefaults.standard.removeObject(forKey: Key.session)
            return false
        }
        // A transient IOKit failure right after login must not forget the session: keep the saved key
        // while trying, and retry once a few seconds later.
        let onChange = controller.onChange
        controller.onChange = nil
        let ok = controller.activate(for: interval, keepDisplayAwake: keepDisplayAwake, activityEvery: activityMinutes)
        controller.onChange = onChange
        if ok {
            refreshIndicator()
        } else if retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.isRunning, !self.controller.isActive else { return }
                _ = self.restoreSession(retry: false)
            }
        }
        return true
    }

    /// Saves the session while it runs; forgets it only when it really ends (turned off, expired,
    /// module disabled), not when Nexo quits with it on.
    private func persistSession() {
        if controller.isActive {
            UserDefaults.standard.set(controller.endDate?.timeIntervalSince1970 ?? 0, forKey: Key.session)
        } else if !NexoCore.isTerminating {
            UserDefaults.standard.removeObject(forKey: Key.session)
        }
    }

    func stop() {
        isRunning = false
        hotKey.unregister()
        controller.deactivate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        lockObservers.removeAll()
    }

    func toggle() {
        guard !controller.isActive else {
            controller.deactivate()
            return
        }
        activate(defaultDuration)
    }

    private func activate(_ duration: KeepAwakeController.Duration) {
        guard isRunning else { return }
        if !controller.activate(duration, keepDisplayAwake: keepDisplayAwake, activityEvery: activityMinutes) {
            NSLog("Nexo: keep awake could not create its power assertion")
        }
    }

    // MARK: Menu

    /// A plain toggle (an item with a submenu never fires its own action) plus a submenu for timed sessions.
    func menuItems() -> [NSMenuItem] {
        let toggleItem = NSMenuItem(title: toggleTitle(), action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = controller.isActive ? .on : .off
        let timed = NSMenuItem(title: "Keep Awake for", action: nil, keyEquivalent: "")
        timed.submenu = durationsMenu()
        return [toggleItem, timed]
    }

    private func durationsMenu() -> NSMenu {
        let menu = NSMenu()
        for duration in KeepAwakeController.Duration.allCases {
            let item = NSMenuItem(title: duration.title, action: #selector(activateFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = duration.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let display = NSMenuItem(title: "Keep display on", action: #selector(toggleDisplayFromMenu), keyEquivalent: "")
        display.target = self
        display.state = keepDisplayAwake ? .on : .off
        menu.addItem(display)
        return menu
    }

    private func toggleTitle() -> String {
        guard controller.isActive else { return "Keep Awake" }
        if controller.isPaused { return "Keep Awake (paused while locked)" }
        guard let remaining = controller.remaining else { return "Keep Awake (on)" }
        return "Keep Awake (\(Self.format(remaining)) left)"
    }

    // MARK: Settings

    func settingsView() -> NSView {
        let status = NSTextField(labelWithString: "")
        statusLabel = status
        let toggle = NSButton(title: "", target: self, action: #selector(toggleFromSettings))
        toggleButton = toggle
        refreshSettingsStatus()

        let display = NSButton(checkboxWithTitle: "Keep the display on (otherwise only the Mac stays awake)", target: self, action: #selector(displayChanged(_:)))
        display.state = keepDisplayAwake ? .on : .off
        let duration = NSPopUpButton()
        KeepAwakeController.Duration.allCases.forEach { duration.addItem(withTitle: $0.title) }
        duration.selectItem(at: KeepAwakeController.Duration.allCases.firstIndex(of: defaultDuration) ?? 0)
        duration.target = self
        duration.action = #selector(durationChanged(_:))
        let activity = NSPopUpButton()
        Self.activityChoices.forEach { activity.addItem(withTitle: $0 == 0 ? "Off" : "Every \($0) min") }
        activity.selectItem(at: Self.activityChoices.firstIndex(of: activityMinutes) ?? 0)
        activity.target = self
        activity.action = #selector(activityChanged(_:))
        let launch = NSButton(checkboxWithTitle: "Start keeping awake when Nexo launches", target: self, action: #selector(launchChanged(_:)))
        launch.state = startOnLaunch ? .on : .off
        let lock = NSButton(checkboxWithTitle: "Pause while the screen is locked", target: self, action: #selector(lockChanged(_:)))
        lock.state = pauseWhenLocked ? .on : .off
        let shortcut = HotKeyField(key: Key.shortcut) { [weak self] in self?.hotKey.register($0) }
        return SettingsForm.stack([
            NSStackView(views: [toggle, status]),
            display,
            SettingsForm.row("Default duration", duration),
            SettingsForm.row("Simulate activity", activity),
            SettingsForm.note("Simulated activity tells macOS the user is present, so the screen saver, the idle lock and “away” status in chat apps don’t kick in."),
            launch,
            lock,
            SettingsForm.row("Toggle shortcut", shortcut),
            SettingsForm.note("A session stays on across quits, restarts and shutdowns until you turn it off (or its time runs out); Nexo resumes it when it launches, so keep “Launch Nexo at login” on in General."),
            SettingsForm.note("Active assertions are listed by `pmset -g assertions` as “\(KeepAwakeController.reason)”. Closing the lid still sleeps the Mac unless an external display is connected."),
        ])
    }

    private func refreshSettingsStatus() {
        toggleButton?.title = controller.isActive ? "Turn Off" : "Turn On"
        statusLabel?.stringValue = controller.isActive ? toggleTitle().replacingOccurrences(of: "Keep Awake", with: "Active") : "Inactive"
        statusLabel?.textColor = controller.isActive ? .systemGreen : .secondaryLabelColor
    }

    private func refreshIndicator() {
        persistSession()
        NexoCore.setStatusIndicator(controller.isActive && !controller.isPaused ? "cup.and.saucer.fill" : nil, owner: Self.id)
        refreshSettingsStatus()
    }

    private func syncLockObservers() {
        let center = DistributedNotificationCenter.default()
        lockObservers.forEach { center.removeObserver($0) }
        lockObservers.removeAll()
        guard isRunning, pauseWhenLocked else {
            controller.resume()
            return
        }
        lockObservers = [
            center.addObserver(forName: Self.lockNotification, object: nil, queue: .main) { [weak self] _ in self?.controller.pause() },
            center.addObserver(forName: Self.unlockNotification, object: nil, queue: .main) { [weak self] _ in self?.controller.resume() },
        ]
    }

    @objc private func toggleFromMenu() { toggle() }

    @objc private func toggleFromSettings() { toggle() }

    @objc private func activateFromMenu(_ sender: NSMenuItem) {
        guard let duration = KeepAwakeController.Duration(rawValue: sender.tag) else { return }
        activate(duration)
    }

    @objc private func toggleDisplayFromMenu() {
        keepDisplayAwake.toggle()
        controller.setKeepDisplayAwake(keepDisplayAwake)
    }

    @objc private func displayChanged(_ sender: NSButton) {
        keepDisplayAwake = sender.state == .on
        controller.setKeepDisplayAwake(keepDisplayAwake)
    }

    @objc private func durationChanged(_ sender: NSPopUpButton) {
        defaultDuration = KeepAwakeController.Duration.allCases[sender.indexOfSelectedItem]
    }

    @objc private func activityChanged(_ sender: NSPopUpButton) {
        activityMinutes = Self.activityChoices[sender.indexOfSelectedItem]
        controller.setActivityInterval(activityMinutes)
    }

    @objc private func launchChanged(_ sender: NSButton) {
        startOnLaunch = sender.state == .on
    }

    @objc private func lockChanged(_ sender: NSButton) {
        pauseWhenLocked = sender.state == .on
    }

    static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
