import Cocoa
import Carbon.HIToolbox

/// Requires holding ⌘Q to quit an app, so a stray press doesn't close it. An active CGEventTap
/// (Accessibility permission) swallows the first ⌘Q, shows a hint, and quits the frontmost app only if
/// the keys are still down after the hold duration.
final class QuitProtectionModule: NexoModule {
    static let id = "quitProtection"
    var title: String { L("Quit Protection") }
    let icon = "shield.lefthalf.filled"
    let permissions: [ModulePermission] = [.accessibility]
    private(set) var isRunning = false

    private enum Key {
        static let exclusions = "quitProtection.exclusions"
        static let hold = "quitProtection.holdSeconds"
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressStart: Date?
    /// True from a ⌘Q keyDown until Q or ⌘ is released. Autorepeat keyDowns while held never start a new
    /// countdown, so holding ⌘Q past one quit can't cascade into quitting the next frontmost app.
    private var qHeld = false
    private var pendingQuit: DispatchWorkItem?
    private let hint = QuitHint()

    private var exclusions: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.exclusions) ?? ["com.apple.finder"] }
        set { UserDefaults.standard.set(newValue, forKey: Key.exclusions) }
    }

    private var holdSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: Key.hold)
        return stored > 0 ? stored : 1
    }

    func start() {
        isRunning = true
        installTap()
    }

    func stop() {
        isRunning = false
        cancel()
        qHeld = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    func settingsView() -> NSView {
        let hold = NSPopUpButton()
        [0.5, 1, 1.5, 2].forEach { hold.addItem(withTitle: "\($0) s"); hold.lastItem?.representedObject = $0 }
        hold.selectItem(withTitle: "\(holdSeconds) s")
        hold.target = self
        hold.action = #selector(holdChanged(_:))
        let list = NSTextField(string: exclusions.joined(separator: ", "))
        list.placeholderString = "com.apple.finder, com.example.app"
        list.widthAnchor.constraint(equalToConstant: 360).isActive = true
        list.target = self
        list.action = #selector(exclusionsChanged(_:))
        return SettingsForm.stack([
            SettingsForm.row(L("Hold ⌘Q for"), hold),
            SettingsForm.row(L("Never protect (bundle ids)"), list),
            SettingsForm.note(tap == nil && isRunning ? L("⚠︎ Needs Accessibility permission; grant it and toggle the module.") : L("Press ⌘Q once to see the hint; keep holding to quit.")),
        ])
    }

    private func installTap() {
        guard tap == nil, AXIsProcessTrusted() else {
            if !AXIsProcessTrusted() { PermissionCenter.request(.accessibility) }
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let module = Unmanaged<QuitProtectionModule>.fromOpaque(context).takeUnretainedValue()
                return module.handle(type, event)
            }, userInfo: context) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that is too slow or on user input timeouts; the key-up may have been lost
        // meanwhile, so drop any countdown before turning it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel()
            qHeld = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let decision = QuitKeyDecision.decide(type: type,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            qHeld: qHeld,
            excluded: type == .keyDown ? isExcluded() : false)
        switch decision {
        case .pass: return Unmanaged.passUnretained(event)
        case .swallow: return nil
        case .startCountdown:
            qHeld = true
            begin()
            return nil
        case .release(let swallow):
            qHeld = false
            cancel()
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
    }

    private func isExcluded() -> Bool {
        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
        return bundleId == Bundle.main.bundleIdentifier || exclusions.contains(bundleId)
    }

    private func begin() {
        pressStart = Date()
        let app = NSWorkspace.shared.frontmostApplication
        hint.show(L("Hold ⌘Q to quit %@", app?.localizedName ?? ""), duration: holdSeconds)
        let work = DispatchWorkItem { [weak self] in
            self?.cancel()
            // Only quit if ⌘Q is physically still down: the release events may never have reached the tap.
            let qDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_Q))
            let commandDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
            guard qDown && commandDown else { return }
            app?.terminate()
        }
        pendingQuit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds, execute: work)
    }

    private func cancel() {
        pressStart = nil
        pendingQuit?.cancel()
        pendingQuit = nil
        hint.hide()
    }

    @objc private func holdChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.selectedItem?.representedObject as? Double ?? 1, forKey: Key.hold)
    }

    @objc private func exclusionsChanged(_ sender: NSTextField) {
        exclusions = sender.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Centered HUD with a progress bar that fills over the hold duration.
final class QuitHint {
    private var panel: NSPanel?
    private var progress: NSProgressIndicator?
    private var timer: Timer?

    func show(_ text: String, duration: Double) {
        let panel = self.panel ?? makePanel()
        (panel.contentView?.subviews.first as? NSStackView)?.views.compactMap { $0 as? NSTextField }.first?.stringValue = text
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2, y: screen.frame.midY - panel.frame.height / 2))
        }
        progress?.doubleValue = 0
        panel.orderFrontRegardless()
        let start = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            self?.progress?.doubleValue = min(1, Date().timeIntervalSince(start) / duration)
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow],
            backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.alignment = .center
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar
        let stack = SettingsForm.stack([label, bar], spacing: 10)
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                bar.widthAnchor.constraint(equalToConstant: 250),
            ])
        }
        self.panel = panel
        progress = bar
        return panel
    }
}

/// Pure ⌘Q state machine for the event tap, unit-testable without CGEvents.
enum QuitKeyDecision: Equatable {
    case pass
    case swallow
    case startCountdown
    case release(swallow: Bool)

    static func decide(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isAutorepeat: Bool, qHeld: Bool, excluded: Bool) -> QuitKeyDecision {
        let isQ = keyCode == Int64(kVK_ANSI_Q)
        let modifiers = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        switch type {
        case .keyDown where isQ && modifiers == .maskCommand:
            if qHeld || isAutorepeat { return qHeld ? .swallow : .pass }
            return excluded ? .pass : .startCountdown
        case .keyUp where isQ && qHeld:
            return .release(swallow: true)
        case .flagsChanged where qHeld && !flags.contains(.maskCommand):
            return .release(swallow: false)
        default:
            return .pass
        }
    }
}
