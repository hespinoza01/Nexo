import Cocoa

/// Switches the keyboard input source automatically when an app becomes active.
final class InputSourceModule: NexoModule {
    static let id = "inputSource"
    var title: String { L("Input Source per App") }
    let icon = "keyboard"
    private(set) var isRunning = false

    private let store = AppRuleStore()
    private var observer: NSObjectProtocol?
    private weak var rulesStack: NSStackView?

    func start() {
        isRunning = true
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.apply(app?.bundleIdentifier)
        }
    }

    func stop() {
        isRunning = false
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    func menuItems() -> [NSMenuItem] {
        let current = InputSourceService.current()
        let info = NSMenuItem(title: L("Current: %@", current?.name ?? L("unknown")), action: nil, keyEquivalent: "")
        info.isEnabled = false
        guard let app = Self.targetApp(), let bundleId = app.bundleIdentifier else { return [info] }
        let pin = NSMenuItem(title: L("Use for %@", app.localizedName ?? bundleId), action: nil, keyEquivalent: "")
        pin.submenu = sourcesMenu(bundleId: bundleId, selected: store.rules[bundleId])
        return [info, pin]
    }

    func settingsView() -> NSView {
        let fallback = sourcePopUp(selected: store.fallbackSourceId, noneTitle: L("Leave unchanged"))
        fallback.target = self
        fallback.action = #selector(fallbackChanged(_:))
        let rules = SettingsForm.stack([], spacing: 6)
        rulesStack = rules
        reloadRules()
        return SettingsForm.stack([
            SettingsForm.row(L("For apps without a rule"), fallback),
            SettingsForm.header(L("Rules")),
            rules,
            NSButton(title: L("Add App…"), target: self, action: #selector(addApp)),
            SettingsForm.note(L("New rules start with the current input source. Also from the Nexo menu while the app is frontmost: “Use for <app>”.")),
        ])
    }

    private func apply(_ bundleId: String?) {
        guard bundleId != Bundle.main.bundleIdentifier, let sourceId = store.sourceId(for: bundleId) else { return }
        InputSourceService.select(sourceId)
    }

    /// The status menu doesn't activate Nexo, so the frontmost app is the one the user is working in.
    private static func targetApp() -> NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
    }

    private func sourcesMenu(bundleId: String, selected: String?) -> NSMenu {
        let menu = NSMenu()
        for source in InputSourceService.selectable() {
            let item = NSMenuItem(title: source.name, action: #selector(pinSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [bundleId, source.id]
            item.state = source.id == selected ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("No rule"), action: #selector(pinSource(_:)), keyEquivalent: "")
        clear.target = self
        clear.representedObject = [bundleId]
        clear.state = selected == nil ? .on : .off
        menu.addItem(clear)
        return menu
    }

    private func reloadRules() {
        guard let rulesStack else { return }
        rulesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rules = store.rules.sorted { Self.appName($0.key) < Self.appName($1.key) }
        guard !rules.isEmpty else {
            rulesStack.addArrangedSubview(SettingsForm.note(L("No rules yet.")))
            return
        }
        rules.forEach { rulesStack.addArrangedSubview(ruleRow(bundleId: $0.key, sourceId: $0.value)) }
    }

    private func ruleRow(bundleId: String, sourceId: String) -> NSView {
        let name = NSTextField(labelWithString: Self.appName(bundleId))
        name.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let popUp = sourcePopUp(selected: sourceId, noneTitle: nil)
        popUp.identifier = .init(bundleId)
        popUp.target = self
        popUp.action = #selector(ruleChanged(_:))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: L("Remove"))!,
            target: self, action: #selector(removeRule(_:)))
        remove.isBordered = false
        remove.identifier = .init(bundleId)
        let row = NSStackView(views: [name, popUp, remove])
        row.spacing = 8
        return row
    }

    private func sourcePopUp(selected: String?, noneTitle: String?) -> NSPopUpButton {
        let popUp = NSPopUpButton()
        if let noneTitle { popUp.addItem(withTitle: noneTitle) }
        for source in InputSourceService.selectable() {
            popUp.addItem(withTitle: source.name)
            popUp.lastItem?.representedObject = source.id
            if source.id == selected { popUp.select(popUp.lastItem) }
        }
        return popUp
    }

    private static func appName(_ bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @objc private func pinSource(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], let bundleId = values.first else { return }
        let sourceId = values.count > 1 ? values[1] : nil
        store.setRule(sourceId, for: bundleId)
        if let sourceId { InputSourceService.select(sourceId) }
        reloadRules()
    }

    @objc private func fallbackChanged(_ sender: NSPopUpButton) {
        store.fallbackSourceId = sender.selectedItem?.representedObject as? String
    }

    @objc private func ruleChanged(_ sender: NSPopUpButton) {
        guard let bundleId = sender.identifier?.rawValue else { return }
        store.setRule(sender.selectedItem?.representedObject as? String, for: bundleId)
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        let add = { [weak self, weak panel] (response: NSApplication.ModalResponse) in
            guard response == .OK, let self, let panel else { return }
            let sourceId = InputSourceService.current()?.id ?? InputSourceService.selectable().first?.id
            guard let sourceId else { return }
            for url in panel.urls {
                guard let bundleId = Bundle(url: url)?.bundleIdentifier, self.store.rules[bundleId] == nil else { continue }
                self.store.setRule(sourceId, for: bundleId)
            }
            self.reloadRules()
        }
        guard let window = NexoCore.settingsHostWindow, window.isVisible else { return add(panel.runModal()) }
        panel.beginSheetModal(for: window, completionHandler: add)
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard let bundleId = sender.identifier?.rawValue else { return }
        store.setRule(nil, for: bundleId)
        reloadRules()
    }
}
