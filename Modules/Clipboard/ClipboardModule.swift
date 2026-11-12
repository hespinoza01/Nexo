import Cocoa
import Carbon.HIToolbox
import ShortcutRecorder

/// Clipboard history with a searchable panel; Return pastes the selected entry into the app that was
/// frontmost when the panel opened.
final class ClipboardModule: NexoModule {
    static let id = "clipboard"
    var title: String { L("Clipboard History") }
    let icon = "doc.on.clipboard"
    let permissions: [ModulePermission] = [.accessibility]
    private(set) var isRunning = false

    private enum Key {
        static let shortcut = "clipboard.shortcut"
        static let excluded = "clipboard.excludedApps"
        static let seeded = "clipboard.shortcutSeeded"
        static let limit = "clipboard.limit"
    }

    private var historyLimit: Int {
        get { ClipboardHistory.limitChoices.contains(UserDefaults.standard.integer(forKey: Key.limit)) ? UserDefaults.standard.integer(forKey: Key.limit) : ClipboardHistory.defaultLimit }
        set { UserDefaults.standard.set(newValue, forKey: Key.limit) }
    }

    private let history = ClipboardHistory()
    private lazy var watcher = ClipboardWatcher(history: history)
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.showPanel() }
    private lazy var panel = ClipboardPanel(history: history) { [weak self] entry, target in self?.paste(entry, into: target) }

    private var excludedApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.excluded) ?? ClipboardWatcher.defaultExcludedApps }
        set { UserDefaults.standard.set(newValue, forKey: Key.excluded) }
    }

    func start() {
        isRunning = true
        history.limit = historyLimit
        watcher.excludedApps = { [weak self] in self?.excludedApps ?? ClipboardWatcher.defaultExcludedApps }
        watcher.start()
        seedShortcutOnce()
        hotKey.register(ShortcutStore.load(Key.shortcut))
    }

    func stop() {
        isRunning = false
        watcher.stop()
        hotKey.unregister()
        panel.close()
    }

    func menuItems() -> [NSMenuItem] {
        let open = NSMenuItem(title: L("Clipboard History…"), action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        let recent = NSMenuItem(title: L("Recent"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, entry) in history.entries.prefix(10).enumerated() {
            let item = NSMenuItem(title: Self.preview(entry.text, length: 50), action: #selector(copyRecent(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            submenu.addItem(item)
        }
        if history.entries.isEmpty { submenu.addItem(withTitle: L("Empty"), action: nil, keyEquivalent: "").isEnabled = false }
        recent.submenu = submenu
        return [open, recent]
    }

    func settingsView() -> NSView {
        let shortcut = HotKeyField(key: Key.shortcut) { [weak self] in self?.hotKey.register($0) }
        let excluded = NSTextField(string: excludedApps.joined(separator: ", "))
        excluded.widthAnchor.constraint(equalToConstant: 380).isActive = true
        excluded.target = self
        excluded.action = #selector(excludedChanged(_:))
        let clear = NSButton(title: L("Clear History"), target: self, action: #selector(clearHistory))
        let limit = NSPopUpButton()
        ClipboardHistory.limitChoices.forEach { limit.addItem(withTitle: L("%d items", $0)) }
        limit.selectItem(at: ClipboardHistory.limitChoices.firstIndex(of: historyLimit) ?? 2)
        limit.target = self
        limit.action = #selector(limitChanged(_:))
        return SettingsForm.stack([
            SettingsForm.row(L("Open panel"), shortcut),
            SettingsForm.row(L("Ignore copies from (bundle ids)"), excluded),
            SettingsForm.row(L("Keep"), limit),
            SettingsForm.note(L("Keeps the last text copies in ~/Library/Application Support/Nexo/clipboard.json (owner-only permissions). Items password managers mark as concealed or transient are never stored; text copied from a plain browser password field has no such mark and is stored.")),
            clear,
        ])
    }

    static func preview(_ text: String, length: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ⏎ ").trimmingCharacters(in: .whitespaces)
        return single.count > length ? String(single.prefix(length)) + "…" : single
    }

    private func showPanel() {
        panel.present(previousApp: NSWorkspace.shared.frontmostApplication)
    }

    /// Put the entry on the pasteboard, give focus back, then synthesize ⌘V (needs Accessibility).
    private func paste(_ entry: ClipboardEntry, into target: NSRunningApplication?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        watcher.markOwnWrite()
        history.add(entry.text, sourceApp: entry.sourceApp)
        guard AXIsProcessTrusted() else {
            PermissionCenter.request(.accessibility)
            return
        }
        target?.activate()
        postPasteWhenFrontmost(target, attempts: 20)
    }

    /// ⌘V must land in the target app, not Nexo: wait (up to ~1s) for it to be frontmost. A private event
    /// source keeps still-held physical modifiers (⌥ from the ⌘⌥V shortcut) out of the synthesized ⌘V.
    private func postPasteWhenFrontmost(_ target: NSRunningApplication?, attempts: Int) {
        let isFront = target == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == target?.processIdentifier
        guard isFront || attempts == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.postPasteWhenFrontmost(target, attempts: attempts - 1) }
            return
        }
        guard isFront else { return }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private func seedShortcutOnce() {
        guard !UserDefaults.standard.bool(forKey: Key.seeded) else { return }
        UserDefaults.standard.set(true, forKey: Key.seeded)
        ShortcutStore.save(Shortcut(code: .ansiV, modifierFlags: [.command, .option], characters: nil, charactersIgnoringModifiers: nil), Key.shortcut)
    }

    @objc private func openFromMenu() { showPanel() }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard history.entries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(history.entries[sender.tag].text, forType: .string)
        watcher.markOwnWrite()
    }

    @objc private func excludedChanged(_ sender: NSTextField) {
        excludedApps = sender.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @objc private func limitChanged(_ sender: NSPopUpButton) {
        historyLimit = ClipboardHistory.limitChoices[sender.indexOfSelectedItem]
        history.limit = historyLimit
    }

    @objc private func clearHistory() {
        history.clear()
    }
}

/// Floating, key-capable panel: search field on top, results below; ↑/↓ to move, Return to paste, Esc to close.
final class ClipboardPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let history: ClipboardHistory
    private let onPick: (ClipboardEntry, NSRunningApplication?) -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private var results = [ClipboardEntry]()
    private var previousApp: NSRunningApplication?

    init(history: ClipboardHistory, onPick: @escaping (ClipboardEntry, NSRunningApplication?) -> Void) {
        self.history = history
        self.onPick = onPick
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        buildLayout()
    }

    override var canBecomeKey: Bool { true }

    func present(previousApp: NSRunningApplication?) {
        self.previousApp = previousApp
        search.stringValue = ""
        reload()
        if let screen = NSScreen.main {
            setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.midY - frame.height / 2 + 80))
        }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(search)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = results[row]
        let label = NSTextField(labelWithString: ClipboardModule.preview(entry.text, length: 90))
        label.lineBreakMode = .byTruncatingTail
        let date = NSTextField(labelWithString: RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: Date()))
        date.textColor = .secondaryLabelColor
        date.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [label, date])
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): pick()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    @objc private func doubleClicked() {
        pick()
    }

    private func reload() {
        results = history.search(search.stringValue)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func pick() {
        guard results.indices.contains(table.selectedRow) else { return }
        let entry = results[table.selectedRow]
        close()
        onPick(entry, previousApp)
    }

    private func buildLayout() {
        search.placeholderString = L("Search clipboard history")
        search.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.headerView = nil
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [search, scroll])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 12, bottom: 12, right: 12)
        contentView = stack
    }
}
