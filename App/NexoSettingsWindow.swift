import Cocoa
import ServiceManagement

/// Settings window: sidebar with "General" plus one entry per registered module.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static let generalId = "general"
    private let registry: ModuleRegistry
    private let sidebar = NSTableView()
    private let content = NSView()
    private var entries: [(id: String, title: String, icon: String)] = []
    private var currentId = SettingsWindowController.generalId
    private var activeObserver: NSObjectProtocol?

    init(registry: ModuleRegistry) {
        self.registry = registry
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Nexo Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        buildLayout()
        reloadEntries()
        // Permissions are granted in System Settings; rebuild the page when the user comes back.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.showPage(self.currentId)
        }
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    func show(moduleId: String?) {
        reloadEntries()
        select(moduleId ?? Self.generalId)
        window?.center()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: entry.icon, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: entry.title)
        let stack = NSStackView(views: [image, label])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard sidebar.selectedRow >= 0 else { return }
        let id = entries[sidebar.selectedRow].id
        guard id != currentId || content.subviews.isEmpty else { return }
        showPage(id)
    }

    private func reloadEntries() {
        entries = [(Self.generalId, "General", "gearshape")] + registry.modules.map { ($0.id, $0.title, $0.icon) }
        sidebar.reloadData()
    }

    private func select(_ id: String) {
        guard let row = entries.firstIndex(where: { $0.id == id }) else { return }
        currentId = id
        sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        showPage(id)
    }

    private func showPage(_ id: String) {
        currentId = id
        content.subviews.forEach { $0.removeFromSuperview() }
        let page = id == Self.generalId ? GeneralPane(registry: registry) : modulePage(id)
        page.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            page.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
    }

    private func modulePage(_ id: String) -> NSView {
        guard let module = registry.module(withId: id) else { return NSView() }
        return ModulePage(module: module, registry: registry)
    }

    private func buildLayout() {
        let column = NSTableColumn(identifier: .init("main"))
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.rowHeight = 28
        sidebar.style = .sourceList
        sidebar.dataSource = self
        sidebar.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = sidebar
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(content)
        let width = scroll.widthAnchor.constraint(equalToConstant: 200)
        width.priority = .defaultLow
        width.isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        window?.contentView = split
    }
}

/// Wraps a module's own settings view with the enable toggle and its permission status.
private final class ModulePage: NSStackView {
    private let module: NexoModule
    private let registry: ModuleRegistry

    init(module: NexoModule, registry: ModuleRegistry) {
        self.module = module
        self.registry = registry
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 16
        addArrangedSubview(header())
        module.permissions.forEach { addArrangedSubview(permissionRow($0)) }
        addArrangedSubview(module.settingsView())
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    private func header() -> NSView {
        let title = NSTextField(labelWithString: module.title)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let toggle = NSSwitch()
        toggle.state = registry.isEnabled(module) ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleModule(_:))
        return NSStackView(views: [title, toggle])
    }

    private func permissionRow(_ permission: ModulePermission) -> NSView {
        let status = PermissionCenter.status(permission)
        let label = NSTextField(labelWithString: "\(permission.title): \(statusText(status))")
        label.textColor = status == .denied ? .systemOrange : .secondaryLabelColor
        guard status == .denied else { return label }
        let button = NSButton(title: "Grant…", target: self, action: #selector(grant(_:)))
        button.identifier = .init(permission.rawValue)
        return NSStackView(views: [label, button])
    }

    private func statusText(_ status: PermissionCenter.Status) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "required"
        case .unknown: return "asked on first use"
        }
    }

    @objc private func toggleModule(_ sender: NSSwitch) {
        registry.setEnabled(sender.state == .on, for: module)
    }

    @objc private func grant(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let permission = ModulePermission(rawValue: raw) else { return }
        PermissionCenter.request(permission)
    }
}

/// General settings: launch at login and the list of modules.
private final class GeneralPane: NSStackView {
    private let registry: ModuleRegistry

    init(registry: ModuleRegistry) {
        self.registry = registry
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 14
        let title = NSTextField(labelWithString: "General")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        addArrangedSubview(title)
        addArrangedSubview(loginItemCheckbox())
        if SMAppService.mainApp.status == .requiresApproval { addArrangedSubview(loginApprovalRow()) }
        addArrangedSubview(NSTextField(labelWithString: "Modules"))
        registry.modules.forEach { addArrangedSubview(moduleCheckbox($0)) }
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    private func loginItemCheckbox() -> NSButton {
        let box = NSButton(checkboxWithTitle: "Launch Nexo at login", target: self, action: #selector(toggleLoginItem(_:)))
        box.state = SMAppService.mainApp.status == .enabled ? .on : .off
        return box
    }

    private func loginApprovalRow() -> NSView {
        let label = NSTextField(labelWithString: "Login item needs approval in System Settings.")
        label.textColor = .systemOrange
        let button = NSButton(title: "Open Login Items…", target: self, action: #selector(openLoginItems))
        return NSStackView(views: [label, button])
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func moduleCheckbox(_ module: NexoModule) -> NSButton {
        let box = NSButton(checkboxWithTitle: module.title, target: self, action: #selector(toggleModule(_:)))
        box.state = registry.isEnabled(module) ? .on : .off
        box.identifier = .init(module.id)
        return box
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        do {
            try sender.state == .on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        } catch {
            NSLog("Nexo: login item change failed: \(error)")
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func toggleModule(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let module = registry.module(withId: id) else { return }
        registry.setEnabled(sender.state == .on, for: module)
    }
}
