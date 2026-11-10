import Cocoa
import Carbon.HIToolbox

/// Requires holding ⌘Q to quit an app, so a stray press doesn't close it. An active CGEventTap
/// (Accessibility permission) swallows the first ⌘Q, shows a hint, and quits the frontmost app only if
/// the keys are still down after the hold duration.
final class QuitProtectionModule: NexoModule {
    static let id = "quitProtection"
    let title = "Quit Protection"
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
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
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
            SettingsForm.row("Hold ⌘Q for", hold),
            SettingsForm.row("Never protect (bundle ids)", list),
            SettingsForm.note(tap == nil && isRunning ? "⚠︎ Needs Accessibility permission; grant it and toggle the module." : "Press ⌘Q once to see the hint; keep holding to quit."),
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
        // macOS disables a tap that is too slow or on user input timeouts; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let isQ = event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_Q)
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        let isCommandQ = isQ && flags == .maskCommand
        switch type {
        case .keyDown where isCommandQ:
            guard !isExcluded() else { return Unmanaged.passUnretained(event) }
            if pressStart == nil { begin() }
            return nil
        case .keyUp where isQ && pressStart != nil:
            cancel()
            return nil
        case .flagsChanged where pressStart != nil && !event.flags.contains(.maskCommand):
            cancel()
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func isExcluded() -> Bool {
        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
        return bundleId == Bundle.main.bundleIdentifier || exclusions.contains(bundleId)
    }

    private func begin() {
        pressStart = Date()
        let app = NSWorkspace.shared.frontmostApplication
        hint.show("Hold ⌘Q to quit \(app?.localizedName ?? "")", duration: holdSeconds)
        let work = DispatchWorkItem { [weak self] in
            self?.cancel()
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
