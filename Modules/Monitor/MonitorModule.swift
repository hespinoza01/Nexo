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
        static let interval = "monitor.interval"
        static let style = "monitor.style"
    }

    private static let intervals: [TimeInterval] = [1, 2, 3, 5]
    private let sampler = MonitorSampler()
    private var statusItem: NSStatusItem?
    private let widget = MonitorWidgetView()
    private let popover = NSPopover()
    private var detail: MonitorDetailViewController?

    private var metrics: [Metric] {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: Key.metrics) ?? [Metric.cpu, .memory].map(\.rawValue)
            return Metric.allCases.filter { stored.contains($0.rawValue) }
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Key.metrics) }
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
        let checkboxes = Metric.allCases.map { metric -> NSButton in
            let box = NSButton(checkboxWithTitle: metric.title, target: self, action: #selector(metricToggled(_:)))
            box.identifier = .init(metric.rawValue)
            box.state = metrics.contains(metric) ? .on : .off
            return box
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
            SettingsForm.stack(checkboxes, spacing: 6),
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
        widget.metrics = metrics
        widget.style = style
        statusItem?.isVisible = !metrics.isEmpty
        sampler.enabledMetrics = Set(Metric.allCases)
        sampler.start(interval: interval)
    }

    private func render(_ sample: MonitorSample) {
        widget.sample = sample
        statusItem?.length = widget.intrinsicContentSize.width
        detail?.update(sample, history: sampler.history)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard !popover.isShown else {
            popover.close()
            return
        }
        let controller = MonitorDetailViewController()
        detail = controller
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        controller.update(sampler.latest, history: sampler.history)
    }

    @objc private func metricToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let metric = Metric(rawValue: raw) else { return }
        var current = metrics
        if sender.state == .on { current.append(metric) } else { current.removeAll { $0 == metric } }
        metrics = current
        applySettings()
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

/// Popover listing every metric with its detail line and a sparkline of the last samples.
final class MonitorDetailViewController: NSViewController {
    private var rows = [Metric: (value: NSTextField, detail: NSTextField, chart: SparklineView)]()

    override func loadView() {
        let stack = SettingsForm.stack([], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for metric in Metric.allCases {
            let title = SettingsForm.header(metric.title)
            let value = NSTextField(labelWithString: "–")
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let detail = SettingsForm.note("")
            let chart = SparklineView()
            rows[metric] = (value, detail, chart)
            let header = NSStackView(views: [title, value])
            stack.addArrangedSubview(SettingsForm.stack([header, detail, chart], spacing: 4))
        }
        view = stack
    }

    func update(_ sample: MonitorSample, history: [Metric: [Double]]) {
        for (metric, row) in rows {
            row.value.stringValue = MonitorWidgetView.value(metric, sample)
            row.value.textColor = MonitorWidgetView.color(metric, sample)
            row.detail.stringValue = Self.detail(metric, sample)
            row.chart.values = history[metric] ?? []
            row.chart.color = metric == .memory ? MonitorWidgetView.color(.memory, sample) : .controlAccentColor
        }
    }

    private static func detail(_ metric: Metric, _ sample: MonitorSample) -> String {
        switch metric {
        case .cpu: return "All cores"
        case .memory:
            let pressure = "Pressure \(MonitorModule.levelName(sample.pressure.level))"
            guard let m = sample.memory else { return pressure }
            return "\(pressure) · Used \(MonitorFormat.bytes(m.used)) of \(MonitorFormat.bytes(m.total)) (app \(MonitorFormat.bytes(m.app)), wired \(MonitorFormat.bytes(m.wired)), compressed \(MonitorFormat.bytes(m.compressed))) · Cached \(MonitorFormat.bytes(m.cached)) · Swap \(MonitorFormat.bytes(m.swapUsed))"
        case .network:
            guard let n = sample.network else { return "–" }
            return "↓ \(MonitorFormat.rate(n.download))  ↑ \(MonitorFormat.rate(n.upload))"
        case .disk:
            let free = sample.diskFree.map { "\(MonitorFormat.bytes(UInt64($0.free))) free of \(MonitorFormat.bytes(UInt64($0.total)))" } ?? "–"
            let io = sample.diskIO.map { " · read \(MonitorFormat.rate($0.read)), write \(MonitorFormat.rate($0.write))" } ?? ""
            return free + io
        case .battery:
            guard let b = sample.battery else { return "No battery" }
            let state = b.isCharging ? "charging" : b.onAC ? "on power adapter" : "on battery"
            return "\(state)\(b.cycleCount.map { " · \($0) cycles" } ?? "")"
        case .temperature:
            guard let t = sample.temperature else { return "Unavailable" }
            return String(format: "Average %.0f°C · hottest %.0f°C", t.average, t.maximum)
        }
    }
}
