import Cocoa
import SwiftUI


/// Stats-style combined popover: one section per metric with a ring gauge, a label/value table and,
/// where it helps, a chart (per-core bars, network up/down, short history) and the top processes.
/// Width, density, colors, visible sections and order come from `MonitorAppearance`.
final class MonitorDetailViewController: NSViewController {
    private let config: MonitorAppearance
    private var style: PopoverStyle { config.popover }
    private var sections = [Metric: MonitorSection]()
    private let cpuRing = RingGaugeView()
    private let cpuTable = InfoTable()
    private let coreBars = CoreBarsView()
    private let cpuProcesses = InfoTable()
    private let gpuRing = RingGaugeView()
    private let gpuTable = InfoTable()
    private let memoryRing = RingGaugeView()
    private let memoryTable = InfoTable()
    private let memoryChart = SparklineView()
    private let memoryProcesses = InfoTable()
    private let networkTable = InfoTable()
    private let networkChart = RateChartView()
    private let addressTable = InfoTable()
    private let diskRing = RingGaugeView()
    private let diskTable = InfoTable()
    private let batteryRing = RingGaugeView()
    private let batteryTable = InfoTable()
    private let temperatureTable = InfoTable()
    private let temperatureChart = SparklineView()

    static let tabKey = "monitor.popover.tab"
    private static let processesWidth: CGFloat = 420
    private static let processesHeight: CGFloat = 460
    private let processes: ProcessListModel
    private let tabs = NSSegmentedControl()
    private var summary: NSStackView?
    private var processesView: NSView?
    private var widthConstraint: NSLayoutConstraint?
    /// Called with true when the Processes tab becomes visible, false when it hides.
    var onTabChange: ((Bool) -> Void)?
    var isShowingProcesses: Bool { tabs.selectedSegment == 1 }

    init(config: MonitorAppearance, processes: ProcessListModel) {
        self.config = config
        self.processes = processes
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    private func color(_ hex: String, _ fallback: NSColor) -> NSColor { NSColor(hex: hex) ?? fallback }

    override func loadView() {
        let density = style.density
        for table in [cpuTable, cpuProcesses, gpuTable, memoryTable, memoryProcesses, networkTable, addressTable, diskTable, batteryTable, temperatureTable] {
            table.rowSpacing = density.rowSpacing
        }
        let title = NSTextField(labelWithString: L("System Monitor"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("Settings"))!,
            target: self, action: #selector(openSettings))
        settings.isBordered = false
        settings.contentTintColor = .secondaryLabelColor
        let activity = NSButton(image: NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: L("Open Activity Monitor"))!,
            target: self, action: #selector(openActivityMonitor))
        activity.isBordered = false
        activity.contentTintColor = .secondaryLabelColor
        activity.toolTip = L("Open Activity Monitor")
        let header = NSStackView(views: [title, NSView(), activity, settings])

        let charts = style.showCharts
        sections[.cpu] = MonitorSection("CPU", [ringRow(cpuRing, cpuTable)] + (style.showCoreBars ? [coreBars] : []) + [cpuProcesses], density: density)
        sections[.gpu] = MonitorSection("GPU", [ringRow(gpuRing, gpuTable)], density: density)
        sections[.memory] = MonitorSection(L("Memory"), [ringRow(memoryRing, memoryTable)] + (charts ? [memoryChart] : []) + [memoryProcesses], density: density)
        sections[.network] = MonitorSection(L("Network"), charts ? [chartRow(networkTable, networkChart), addressTable] : [networkTable, addressTable], density: density)
        sections[.disk] = MonitorSection(L("Disk"), [ringRow(diskRing, diskTable)], density: density)
        sections[.battery] = MonitorSection(L("Battery"), [ringRow(batteryRing, batteryTable)], density: density)
        sections[.temperature] = MonitorSection(L("Temperature"), [temperatureTable] + (charts ? [temperatureChart] : []), density: density)

        let visible = config.orderedMetrics.filter(config.isSectionVisible).compactMap { sections[$0] }
        let summary = NSStackView(views: visible)
        summary.orientation = .vertical
        summary.alignment = .leading
        summary.spacing = density.sectionSpacing
        for view in visible { view.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true }
        self.summary = summary

        let processesView = NSHostingView(rootView: ProcessListView(model: processes))
        processesView.heightAnchor.constraint(equalToConstant: Self.processesHeight).isActive = true
        self.processesView = processesView

        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        tabs.segmentCount = 2
        tabs.setLabel(L("Summary"), forSegment: 0)
        tabs.setLabel(L("Processes"), forSegment: 1)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = UserDefaults.standard.integer(forKey: Self.tabKey) == 1 ? 1 : 0

        let stack = NSStackView(views: [header, tabs, summary, processesView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = density.sectionSpacing
        let inset = density.padding + 2
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * inset).isActive = true
        }
        widthConstraint = stack.widthAnchor.constraint(equalToConstant: summaryWidth)
        widthConstraint?.isActive = true
        view = stack
        applyTab()
    }

    private var summaryWidth: CGFloat { CGFloat(style.width.clamped(260, 420)) }

    @objc private func tabChanged() {
        UserDefaults.standard.set(tabs.selectedSegment, forKey: Self.tabKey)
        applyTab()
        onTabChange?(isShowingProcesses)
    }

    /// The process list needs room for four columns, so that tab is wider than a narrow summary.
    private func applyTab() {
        let showing = isShowingProcesses
        summary?.isHidden = showing
        processesView?.isHidden = !showing
        widthConstraint?.constant = showing ? max(summaryWidth, Self.processesWidth) : summaryWidth
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    func update(_ sample: MonitorSample, history: [Metric: [Double]], networkHistory: [(download: Double, upload: Double)]) {
        updateCPU(sample)
        updateGPU(sample)
        updateMemory(sample, history: history[.memory] ?? [])
        updateNetwork(sample, history: networkHistory)
        updateDisk(sample)
        updateBattery(sample)
        updateTemperature(sample, history: history[.temperature] ?? [])
    }

    func update(processes: TopProcesses) {
        cpuProcesses.isHidden = processes.byCPU.isEmpty
        cpuProcesses.rows = processes.byCPU.map { .init($0.name, String(format: "%.1f%%", $0.cpu)) }
        memoryProcesses.isHidden = processes.byMemory.isEmpty
        memoryProcesses.rows = processes.byMemory.map { .init($0.name, MonitorFormat.bytes($0.memory)) }
    }

    private func updateCPU(_ sample: MonitorSample) {
        let ring = config.color(.cpu, sample)
        guard let load = sample.cpuLoad else {
            cpuRing.set(nil, color: ring)
            return
        }
        cpuRing.set(load.total, color: ring)
        let efficiency = min(CPUTopology.efficiencyCores, load.perCore.count)
        let eColor = color(style.efficiencyColor, .systemTeal)
        let pColor = color(style.performanceColor, .systemIndigo)
        var rows: [InfoTable.Row] = [
            .init(L("Usage"), MonitorFormat.percent(load.total)),
            .init(L("System"), MonitorFormat.percent(load.system), dot: color(style.systemColor, .systemRed)),
            .init(L("User"), MonitorFormat.percent(load.user), dot: color(style.userColor, .systemBlue)),
            .init(L("Idle"), MonitorFormat.percent(load.idle)),
        ]
        if efficiency > 0, efficiency < load.perCore.count {
            let average = { (cores: ArraySlice<Double>) in cores.reduce(0, +) / Double(max(1, cores.count)) }
            rows.append(.init(L("E-cores"), MonitorFormat.percent(average(load.perCore[..<efficiency])), dot: eColor))
            rows.append(.init(L("P-cores"), MonitorFormat.percent(average(load.perCore[efficiency...])), dot: pColor))
        }
        if let temperature = sample.temperature, !config.isSectionVisible(.temperature) {
            rows.append(.init(L("Temperature"), String(format: "%.0f °C", temperature.maximum), valueColor: Self.alertTint(config.color(.temperature, sample))))
        }
        cpuTable.rows = rows
        coreBars.set(load.perCore, efficiencyCores: efficiency, efficiencyColor: eColor, performanceColor: pColor)
    }

    private func updateGPU(_ sample: MonitorSample) {
        sections[.gpu]?.isHidden = sample.gpu == nil
        guard let gpu = sample.gpu else { return }
        gpuRing.set(gpu.device, color: config.color(.gpu, sample))
        gpuTable.rows = [
            .init(L("Usage"), MonitorFormat.percent(gpu.device)),
            gpu.renderer.map { .init(L("Renderer"), MonitorFormat.percent($0)) },
            gpu.tiler.map { .init(L("Tiler"), MonitorFormat.percent($0)) },
        ].compactMap { $0 }
    }

    /// The ring follows the kernel's memory pressure (what Activity Monitor graphs); occupancy is
    /// listed below it.
    private func updateMemory(_ sample: MonitorSample, history: [Double]) {
        let ring = config.color(.memory, sample)
        let level = MonitorWidgetView.color(.memory, sample)
        memoryRing.set(sample.pressure.percent.map { Double($0) / 100 }, color: ring)
        var rows: [InfoTable.Row] = [.init(L("Pressure"), MonitorModule.levelName(sample.pressure.level), valueColor: level)]
        if let m = sample.memory {
            rows += [
                .init(L("Used"), MonitorFormat.usedOfTotal(m.used, m.total)),
                .init(L("App"), MonitorFormat.bytes(m.app), dot: color(style.appColor, .systemBlue)),
                .init(L("Wired"), MonitorFormat.bytes(m.wired), dot: color(style.wiredColor, .systemOrange)),
                .init(L("Compressed"), MonitorFormat.bytes(m.compressed), dot: color(style.compressedColor, .systemPink)),
                .init(L("Cached"), MonitorFormat.bytes(m.cached)),
                .init(L("Swap"), MonitorFormat.bytes(m.swapUsed)),
            ]
        }
        memoryTable.rows = rows
        memoryChart.values = history
        memoryChart.color = ring
    }

    private func updateNetwork(_ sample: MonitorSample, history: [(download: Double, upload: Double)]) {
        let up = color(style.uploadColor, .systemRed)
        let down = color(style.downloadColor, .systemBlue)
        networkTable.rows = [
            .init(L("Upload"), sample.network.map { MonitorFormat.rate($0.upload) } ?? "–", dot: up),
            .init(L("Download"), sample.network.map { MonitorFormat.rate($0.download) } ?? "–", dot: down),
        ]
        networkChart.set(history, uploadColor: up, downloadColor: down)
        addressTable.rows = [
            .init(L("Local IP"), sample.localAddress.map { "\($0.address) (\($0.interface))" } ?? L("Offline")),
        ]
    }

    private func updateDisk(_ sample: MonitorSample) {
        sections[.disk]?.isHidden = sample.diskFree == nil
        guard let space = sample.diskFree else { return }
        let used = 1 - Double(space.free) / Double(max(1, space.total))
        diskRing.set(used, color: config.color(.disk, sample))
        diskTable.rows = [
            .init(L("Free"), MonitorFormat.bytes(UInt64(space.free))),
            .init(L("Total"), MonitorFormat.bytes(UInt64(space.total))),
            .init(L("Read"), sample.diskIO.map { MonitorFormat.rate($0.read) } ?? "–"),
            .init(L("Write"), sample.diskIO.map { MonitorFormat.rate($0.write) } ?? "–"),
        ]
    }

    private func updateBattery(_ sample: MonitorSample) {
        sections[.battery]?.isHidden = sample.battery == nil
        guard let battery = sample.battery else { return }
        batteryRing.set(Double(battery.percent) / 100, color: config.color(.battery, sample))
        batteryTable.rows = [
            .init(L("State"), battery.isCharging ? L("Charging") : battery.onAC ? L("Power adapter") : L("On battery")),
            battery.cycleCount.map { .init(L("Cycles"), "\($0)") },
        ].compactMap { $0 }
    }

    private func updateTemperature(_ sample: MonitorSample, history: [Double]) {
        sections[.temperature]?.isHidden = sample.temperature == nil
        guard let temperature = sample.temperature else { return }
        let tint = config.color(.temperature, sample)
        temperatureTable.rows = [
            .init(L("Average"), String(format: "%.0f °C", temperature.average)),
            .init(L("Hottest"), String(format: "%.0f °C", temperature.maximum), valueColor: Self.alertTint(tint)),
        ]
        temperatureChart.values = history
        temperatureChart.color = tint
    }

    /// Values stay in the label color unless the metric is in a warning state.
    private static func alertTint(_ color: NSColor) -> NSColor? {
        [NSColor.systemOrange, .systemRed, .systemYellow].contains(color) ? color : nil
    }

    @objc private func openSettings() {
        view.window?.performClose(nil)
        NexoCore.showSettings(moduleId: MonitorModule.id)
    }

    @objc private func openActivityMonitor() {
        view.window?.performClose(nil)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func ringRow(_ ring: RingGaugeView, _ table: InfoTable) -> NSView {
        let row = NSStackView(views: [ring, table])
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func chartRow(_ table: InfoTable, _ chart: NSView) -> NSView {
        let row = NSStackView(views: [table, chart])
        row.alignment = .centerY
        row.spacing = 10
        table.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return row
    }
}

/// A rounded card with a section title and its content views stacked full width.
final class MonitorSection: NSView {
    init(_ title: String, _ content: [NSView], density: PopoverDensity = .regular) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        let stack = NSStackView(views: [label] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = density.rowSpacing * 2 + 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: density.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -density.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: density.padding - 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(density.padding - 2)),
        ])
        for view in content {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
    }
}

/// Label/value rows: label (with optional color dot) on the left, monospaced value right-aligned.
final class InfoTable: NSView {
    struct Row {
        let label: String
        let value: String
        var dot: NSColor?
        var valueColor: NSColor?

        init(_ label: String, _ value: String, dot: NSColor? = nil, valueColor: NSColor? = nil) {
            self.label = label
            self.value = value
            self.dot = dot
            self.valueColor = valueColor
        }
    }

    private let grid = NSGridView()
    private var labels = [NSTextField]()
    private var values = [NSTextField]()
    private var dots = [ColorDotView]()

    var rows = [Row]() { didSet { render() } }
    var rowSpacing: CGFloat {
        get { grid.rowSpacing }
        set { grid.rowSpacing = newValue }
    }

    init() {
        super.init(frame: .zero)
        grid.rowSpacing = 2
        grid.columnSpacing = 4
        grid.translatesAutoresizingMaskIntoConstraints = false
        // Hug vertically: inside a row next to a taller ring the grid would otherwise spread rows apart.
        setContentHuggingPriority(.required, for: .vertical)
        grid.setContentHuggingPriority(.required, for: .vertical)
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    /// Reuses the row views: rebuilding the grid every sample would flicker.
    private func render() {
        while labels.count < rows.count { addRow() }
        for index in 0..<labels.count {
            let visible = index < rows.count
            grid.row(at: index).isHidden = !visible
            guard visible else { continue }
            let row = rows[index]
            labels[index].stringValue = row.label + ":"
            values[index].stringValue = row.value
            values[index].textColor = row.valueColor ?? .labelColor
            dots[index].color = row.dot
        }
    }

    private func addRow() {
        let dot = ColorDotView()
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        value.alignment = .right
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        grid.addRow(with: [dot, label, value])
        grid.column(at: 0).width = 8
        grid.column(at: 2).xPlacement = .trailing
        labels.append(label)
        values.append(value)
        dots.append(dot)
    }
}

final class ColorDotView: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: (bounds.height - 8) / 2, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
    }
}

/// Ring gauge with the percentage in the middle.
final class RingGaugeView: NSView {
    private var fraction: Double?
    private var color = NSColor.controlAccentColor
    private static let size: CGFloat = 58
    private static let lineWidth: CGFloat = 6

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    func set(_ fraction: Double?, color: NSColor) {
        self.fraction = fraction.map { max(0, min(1, $0)) }
        self.color = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: 0, width: Self.size, height: Self.size).insetBy(dx: Self.lineWidth / 2 + 1, dy: Self.lineWidth / 2 + 1)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = Self.lineWidth
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()
        if let fraction, fraction > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
            arc.lineWidth = Self.lineWidth
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        }
        let text = fraction.map(MonitorFormat.percent) ?? "–"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
    }
}

/// One bar per logical core, efficiency cores first in their own color.
final class CoreBarsView: NSView {
    private var values = [Double]()
    private var efficiencyCores = 0
    private var efficiencyColor = NSColor.systemTeal
    private var performanceColor = NSColor.systemIndigo

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }

    func set(_ values: [Double], efficiencyCores: Int, efficiencyColor: NSColor, performanceColor: NSColor) {
        self.values = values
        self.efficiencyCores = efficiencyCores
        self.efficiencyColor = efficiencyColor
        self.performanceColor = performanceColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * (width + gap)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: bounds.height), xRadius: 2, yRadius: 2).fill()
            let height = max(2, bounds.height * CGFloat(max(0, min(1, value))))
            (index < efficiencyCores ? efficiencyColor : performanceColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: height), xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// Network history mirrored around the middle line: upload above, download below, each scaled to
/// the busiest sample in the window.
final class RateChartView: NSView {
    private var history = [(download: Double, upload: Double)]()
    private var uploadColor = NSColor.systemRed
    private var downloadColor = NSColor.systemBlue

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }

    func set(_ history: [(download: Double, upload: Double)], uploadColor: NSColor, downloadColor: NSColor) {
        self.history = history
        self.uploadColor = uploadColor
        self.downloadColor = downloadColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        guard !history.isEmpty else { return }
        let peak = max(1024, history.map { max($0.download, $0.upload) }.max() ?? 0)
        let half = bounds.height / 2 - 2
        let step = bounds.width / CGFloat(MonitorSampler.historyLength)
        let offset = CGFloat(MonitorSampler.historyLength - history.count) * step
        for (index, point) in history.enumerated() {
            let x = offset + CGFloat(index) * step
            let up = half * CGFloat(point.upload / peak)
            let down = half * CGFloat(point.download / peak)
            uploadColor.setFill()
            NSRect(x: x, y: bounds.midY, width: max(1, step - 1), height: up).fill()
            downloadColor.setFill()
            NSRect(x: x, y: bounds.midY - down, width: max(1, step - 1), height: down).fill()
        }
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 0.5).fill()
    }
}
