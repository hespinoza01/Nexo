import Cocoa

/// Nexo module wrapping the AltTab-derived window switcher.
/// The switcher's model, taps and background threads are process-lifetime singletons that were never
/// designed to be torn down, so `stop()` only disables the global shortcuts and hides the UI; the
/// heavy launch runs once per process, on the first `start()`.
final class SwitcherModule: NexoModule {
    static let id = "switcher"
    var title: String { L("Window Switcher") }
    let icon = "rectangle.on.rectangle"
    let permissions: [ModulePermission] = [.accessibility, .screenRecording]
    private(set) var isRunning = false
    private static var launched = false

    func start() {
        isRunning = true
        App.isSwitcherEnabled = true
        guard Self.launched else {
            Self.launched = true
            App.startSwitcher()
            return
        }
        guard App.didContinueAppLaunch else { return }
        KeyboardEvents.toggleGlobalShortcuts(false)
        ControlsTab.toggleNativeCommandTabIfNeeded()
        // Re-apply the per-app exceptions for whatever is frontmost right now.
        if let pid = Applications.frontmostPid, let app = Applications.findOrCreate(pid) {
            App.checkIfShortcutsShouldBeDisabled(app.focusedWindow, app)
        }
    }

    /// `App.isSwitcherEnabled` is what makes this durable: the switcher re-evaluates its shortcuts on
    /// every app/window activation and would otherwise re-register them.
    func stop() {
        isRunning = false
        App.isSwitcherEnabled = false
        App.hideUi()
        KeyboardEvents.toggleGlobalShortcuts(true)
        // Give ⌘Tab back to macOS while the switcher is off.
        if App.didContinueAppLaunch { setNativeCommandTabEnabled(true) }
    }

    func menuItems() -> [NSMenuItem] {
        Menubar.moduleMenuItems()
    }

    var settingsFillsHeight: Bool { true }

    /// The switcher's own sections (Appearance, Controls, General, Exceptions), embedded in Nexo's
    /// settings window: a section picker and search on top, the sections scrolling below.
    func settingsView() -> NSView {
        guard isRunning, let window = App.settingsWindowForEmbedding() else {
            return NSTextField(wrappingLabelWithString: isRunning
                ? L("The window switcher is still starting (it waits for Accessibility and Screen Recording). Come back in a moment.")
                : L("Enable the module to configure the window switcher."))
        }
        return SwitcherSettingsPane(window: window, host: NexoCore.settingsHostWindow)
    }
}

/// Section picker + search over the embedded `SettingsWindow` sections pane.
private final class SwitcherSettingsPane: NSView, NSSearchFieldDelegate {
    private let settings: SettingsWindow
    private let picker: NSSegmentedControl
    private let search = NSSearchField()
    private let ids: [String]

    init(window: SettingsWindow, host: NSWindow?) {
        self.settings = window
        let sections = window.sectionTitles
        ids = sections.map(\.id)
        picker = NSSegmentedControl(labels: sections.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        picker.target = self
        picker.action = #selector(pick(_:))
        picker.selectedSegment = 0
        search.placeholderString = L("Search switcher settings")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let content = window.embeddedContent(host: host)
        let bar = NSStackView(views: [picker, NSView(), search])
        bar.translatesAutoresizingMaskIntoConstraints = false
        [bar, content].forEach(addSubview)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            search.widthAnchor.constraint(equalToConstant: 200),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let minWidth = content.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsWindow.contentWidth + 40)
        minWidth.priority = .init(999)
        minWidth.isActive = true
        window.onSectionSelected = { [weak self] id in
            guard let self, let index = self.ids.firstIndex(of: id) else { return }
            self.picker.selectedSegment = index
        }
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    @objc private func pick(_ sender: NSSegmentedControl) {
        guard ids.indices.contains(sender.selectedSegment) else { return }
        settings.navigateToSection(ids[sender.selectedSegment])
    }

    func controlTextDidChange(_ notification: Notification) {
        settings.search(search.stringValue)
    }
}
