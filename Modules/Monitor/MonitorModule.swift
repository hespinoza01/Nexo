import Cocoa

/// System monitor in its own status item (Stats-like readouts), with a detail popover and history.
/// Memory is shown as the kernel's memory pressure, like Activity Monitor; occupancy is listed apart.
final class MonitorModule: NexoModule {
    static let id = "monitor"
    let title = "System Monitor"
    let icon = "gauge.with.dots.needle.33percent"
    private(set) var isRunning = false

    private enum Key {
        static let metrics = "monitor.metrics"
        static let order = "monitor.order"
        static let interval = "monitor.interval"
        static let style = "monitor.style"
    }

    private static let intervals: [TimeInterval] = [1, 2, 3, 5]
    private let sampler = MonitorSampler()
    private var statusItem: NSStatusItem?
    private let widget = MonitorWidgetView()
    private let popover = NSPopover()
    private var detail: MonitorDetailViewController?

    /// Metrics shown in the menu bar, in the user's order.
    private var metrics: [Metric] {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: Key.metrics) ?? [Metric.cpu, .memory].map(\.rawValue)
            return order.filter { stored.contains($0.rawValue) }
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Key.metrics) }
    }

    /// Every metric in the user's order (menu bar and popover); metrics added in later versions go last.
    private var order: [Metric] {
        get {
            let stored = (UserDefaults.standard.stringArray(forKey: Key.order) ?? []).compactMap(Metric.init(rawValue:))
            return stored + Metric.allCases.filter { !stored.contains($0) }
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Key.order) }
    }

    private var interval: TimeInterval {
        get { Self.intervals.contains(UserDefaults.standard.double(forKey: Key.interval)) ? UserDefaults.standard.double(forKey: Key.interval) : 2 }
        set { UserDefaults.standard.set(newValue, forKey: Key.interval) }
    }

    private var style: MonitorWidgetStyle {
        get { MonitorWidgetStyle(rawValue: UserDefaults.standard.integer(forKey: Key.style)) ?? .text }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.style) }
    }

    func start() {
        isRunning = true
        installStatusItem()
        sampler.onSample = { [weak self] sample in self?.render(sample) }
        applySettings()
    }

    func stop() {
        isRunning = false
        sampler.stop()
        popover.close()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func menuItems() -> [NSMenuItem] {
        let sample = sampler.latest
        var lines = ["Memory pressure: \(sample.pressure.percent.map { "\($0)%" } ?? "–") (\(Self.levelName(sample.pressure.level)))"]
        if let cpu = sample.cpu { lines.append("CPU: \(MonitorFormat.percent(cpu))") }
        return lines.map {
            let item = NSMenuItem(title: $0, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
    }

    func settingsView() -> NSView {
        let list = MetricOrderList(order: order, enabled: Set(metrics))
        list.onChange = { [weak self] order, enabled in
            guard let self else { return }
            self.order = order
            self.metrics = order.filter(enabled.contains)
            self.refreshWidget()
        }
        let intervalPopUp = NSPopUpButton()
        Self.intervals.forEach { intervalPopUp.addItem(withTitle: "\(Int($0)) s") }
        intervalPopUp.selectItem(at: Self.intervals.firstIndex(of: interval) ?? 1)
        intervalPopUp.target = self
        intervalPopUp.action = #selector(intervalChanged(_:))
        let stylePopUp = NSPopUpButton()
        MonitorWidgetStyle.allCases.forEach { stylePopUp.addItem(withTitle: $0.title) }
        stylePopUp.selectItem(at: style.rawValue)
        stylePopUp.target = self
        stylePopUp.action = #selector(styleChanged(_:))
        return SettingsForm.stack([
            SettingsForm.header("Shown in the menu bar"),
            list,
            SettingsForm.note("Drag to reorder. The order applies to the menu bar and to the detail popover."),
            SettingsForm.row("Update every", intervalPopUp),
            SettingsForm.row("Widget style", stylePopUp),
            SettingsForm.note("Memory shows the kernel's memory pressure, the same value and color as Activity Monitor (green normal, yellow warning, red critical). Used/wired/compressed memory is in the detail popover. Temperatures use a private macOS API and may be missing on some versions."),
        ])
    }

    static func levelName(_ level: MemoryPressure.Level) -> String {
        switch level {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "NexoMonitor"
        guard let button = item.button else { return }
        widget.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(widget)
        NSLayoutConstraint.activate([
            widget.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            widget.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            widget.topAnchor.constraint(equalTo: button.topAnchor),
            widget.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        button.target = self
        button.action = #selector(togglePopover(_:))
        statusItem = item
    }

    private func applySettings() {
        refreshWidget()
        sampler.enabledMetrics = Set(Metric.allCases)
        sampler.start(interval: interval)
    }

    private func refreshWidget() {
        widget.metrics = metrics
        widget.style = style
        statusItem?.isVisible = !metrics.isEmpty
        statusItem?.length = widget.intrinsicContentSize.width
    }

    private func render(_ sample: MonitorSample) {
        widget.sample = sample
        statusItem?.length = widget.intrinsicContentSize.width
        guard popover.isShown else { return }
        detail?.update(sample, history: sampler.history, networkHistory: sampler.networkHistory)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard !popover.isShown else {
            popover.close()
            detail = nil
            return
        }
        let controller = MonitorDetailViewController(order: order)
        detail = controller
        _ = controller.view
        controller.update(sampler.latest, history: sampler.history, networkHistory: sampler.networkHistory)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        interval = Self.intervals[sender.indexOfSelectedItem]
        applySettings()
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        style = MonitorWidgetStyle(rawValue: sender.indexOfSelectedItem) ?? .text
        applySettings()
    }
}

/// Metric list for settings: checkbox to show it in the menu bar, drag to reorder.
final class MetricOrderList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private static let dragType = NSPasteboard.PasteboardType("com.luckylopolis.nexo.monitor.metric")
    private let table = NSTableView()
    private var order: [Metric]
    private var enabled: Set<Metric>
    var onChange: (([Metric], Set<Metric>) -> Void)?

    init(order: [Metric], enabled: Set<Metric>) {
        self.order = order
        self.enabled = enabled
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 0))
        let column = NSTableColumn(identifier: .init("metric"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        documentView = table
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        borderType = .noBorder
        drawsBackground = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 260).isActive = true
        heightAnchor.constraint(equalToConstant: CGFloat(order.count) * (table.rowHeight + table.intercellSpacing.height) + 12).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let metric = order[row]
        let box = NSButton(checkboxWithTitle: metric.title, target: self, action: #selector(toggled(_:)))
        box.identifier = .init(metric.rawValue)
        box.state = enabled.contains(metric) ? .on : .off
        let handle = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to reorder")!)
        handle.contentTintColor = .tertiaryLabelColor
        let row = NSStackView(views: [box, NSView(), handle])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        return row
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let from = Int(raw), order.indices.contains(from) else { return false }
        let metric = order.remove(at: from)
        order.insert(metric, at: from < row ? row - 1 : row)
        tableView.reloadData()
        onChange?(order, enabled)
        return true
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let metric = Metric(rawValue: raw) else { return }
        if sender.state == .on { enabled.insert(metric) } else { enabled.remove(metric) }
        onChange?(order, enabled)
    }
}
