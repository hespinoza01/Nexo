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
        guard popover.isShown else { return }
        detail?.update(sample, history: sampler.history, networkHistory: sampler.networkHistory)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard !popover.isShown else {
            popover.close()
            detail = nil
            return
        }
        let controller = MonitorDetailViewController()
        detail = controller
        _ = controller.view
        controller.update(sampler.latest, history: sampler.history, networkHistory: sampler.networkHistory)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
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
