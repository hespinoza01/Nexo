import Cocoa

/// Stats-style combined popover: one section per metric with a ring gauge, a label/value table and,
/// where it helps, a chart (per-core bars, network up/down, short history). Fixed width so long
/// values truncate instead of stretching or clipping the popover.
final class MonitorDetailViewController: NSViewController {
    static let width: CGFloat = 300
    private static let efficiencyColor = NSColor.systemTeal
    private static let performanceColor = NSColor.systemIndigo
    private static let uploadColor = NSColor.systemRed
    private static let downloadColor = NSColor.systemBlue

    private var sections = [Metric: MonitorSection]()
    private let cpuRing = RingGaugeView()
    private let cpuTable = InfoTable()
    private let coreBars = CoreBarsView()
    private let gpuRing = RingGaugeView()
    private let gpuTable = InfoTable()
    private let memoryRing = RingGaugeView()
    private let memoryTable = InfoTable()
    private let memoryChart = SparklineView()
    private let networkTable = InfoTable()
    private let networkChart = RateChartView()
    private let addressTable = InfoTable()
    private let diskRing = RingGaugeView()
    private let diskTable = InfoTable()
    private let batteryRing = RingGaugeView()
    private let batteryTable = InfoTable()

    override func loadView() {
        let title = NSTextField(labelWithString: "System Monitor")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
            target: self, action: #selector(openSettings))
        settings.isBordered = false
        settings.contentTintColor = .secondaryLabelColor
        let header = NSStackView(views: [title, NSView(), settings])
        header.distribution = .fill

        sections[.cpu] = MonitorSection("CPU", [Self.ringRow(cpuRing, cpuTable), coreBars])
        sections[.gpu] = MonitorSection("GPU", [Self.ringRow(gpuRing, gpuTable)])
        sections[.memory] = MonitorSection("Memory", [Self.ringRow(memoryRing, memoryTable), memoryChart])
        sections[.network] = MonitorSection("Network", [Self.chartRow(networkTable, networkChart), addressTable])
        sections[.disk] = MonitorSection("Disk", [Self.ringRow(diskRing, diskTable)])
        sections[.battery] = MonitorSection("Battery", [Self.ringRow(batteryRing, batteryTable)])

        let stack = NSStackView(views: [header] + Metric.allCases.compactMap { sections[$0] })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
    }

    func update(_ sample: MonitorSample, history: [Metric: [Double]], networkHistory: [(download: Double, upload: Double)]) {
        updateCPU(sample)
        updateGPU(sample)
        updateMemory(sample, history: history[.memory] ?? [])
        updateNetwork(sample, history: networkHistory)
        updateDisk(sample)
        updateBattery(sample)
    }

    private func updateCPU(_ sample: MonitorSample) {
        guard let load = sample.cpuLoad else {
            cpuRing.set(nil, color: .controlAccentColor)
            return
        }
        cpuRing.set(load.total, color: MonitorWidgetView.color(.cpu, sample) == .labelColor ? .controlAccentColor : MonitorWidgetView.color(.cpu, sample))
        let efficiency = min(CPUTopology.efficiencyCores, load.perCore.count)
        var rows: [InfoTable.Row] = [
            .init("Usage", MonitorFormat.percent(load.total)),
            .init("System", MonitorFormat.percent(load.system)),
            .init("User", MonitorFormat.percent(load.user)),
            .init("Idle", MonitorFormat.percent(load.idle)),
        ]
        if efficiency > 0, efficiency < load.perCore.count {
            let average = { (cores: ArraySlice<Double>) in cores.reduce(0, +) / Double(max(1, cores.count)) }
            rows.append(.init("E-cores", MonitorFormat.percent(average(load.perCore[..<efficiency])), dot: Self.efficiencyColor))
            rows.append(.init("P-cores", MonitorFormat.percent(average(load.perCore[efficiency...])), dot: Self.performanceColor))
        }
        if let temperature = sample.temperature {
            let color = MonitorWidgetView.color(.temperature, sample)
            rows.append(.init("Temperature", String(format: "%.0f °C", temperature.maximum), valueColor: color == .labelColor ? nil : color))
        }
        cpuTable.rows = rows
        coreBars.set(load.perCore, efficiencyCores: efficiency, efficiencyColor: Self.efficiencyColor, performanceColor: Self.performanceColor)
    }

    private func updateGPU(_ sample: MonitorSample) {
        sections[.gpu]?.isHidden = sample.gpu == nil
        guard let gpu = sample.gpu else { return }
        gpuRing.set(gpu.device, color: .systemBlue)
        gpuTable.rows = [
            .init("Usage", MonitorFormat.percent(gpu.device)),
            gpu.renderer.map { .init("Renderer", MonitorFormat.percent($0)) },
            gpu.tiler.map { .init("Tiler", MonitorFormat.percent($0)) },
        ].compactMap { $0 }
    }

    /// The ring and its color are the kernel's memory pressure (what Activity Monitor graphs);
    /// occupancy is listed below it, never used for the color.
    private func updateMemory(_ sample: MonitorSample, history: [Double]) {
        let color = MonitorWidgetView.color(.memory, sample)
        memoryRing.set(sample.pressure.percent.map { Double($0) / 100 }, color: color)
        var rows: [InfoTable.Row] = [.init("Pressure", MonitorModule.levelName(sample.pressure.level), valueColor: color)]
        if let m = sample.memory {
            rows += [
                .init("Used", "\(MonitorFormat.gigabytes(m.used)) / \(MonitorFormat.gigabytes(m.total))"),
                .init("App", MonitorFormat.bytes(m.app), dot: .systemBlue),
                .init("Wired", MonitorFormat.bytes(m.wired), dot: .systemOrange),
                .init("Compressed", MonitorFormat.bytes(m.compressed), dot: .systemPink),
                .init("Cached", MonitorFormat.bytes(m.cached)),
                .init("Swap", MonitorFormat.bytes(m.swapUsed)),
            ]
        }
        memoryTable.rows = rows
        memoryChart.values = history
        memoryChart.color = color
    }

    private func updateNetwork(_ sample: MonitorSample, history: [(download: Double, upload: Double)]) {
        networkTable.rows = [
            .init("Upload", sample.network.map { MonitorFormat.rate($0.upload) } ?? "–", dot: Self.uploadColor),
            .init("Download", sample.network.map { MonitorFormat.rate($0.download) } ?? "–", dot: Self.downloadColor),
        ]
        networkChart.set(history, uploadColor: Self.uploadColor, downloadColor: Self.downloadColor)
        addressTable.rows = [
            .init("Local IP", sample.localAddress.map { "\($0.address) (\($0.interface))" } ?? "Offline"),
        ]
    }

    private func updateDisk(_ sample: MonitorSample) {
        sections[.disk]?.isHidden = sample.diskFree == nil
        guard let space = sample.diskFree else { return }
        let used = 1 - Double(space.free) / Double(max(1, space.total))
        diskRing.set(used, color: used > 0.9 ? .systemRed : .systemPurple)
        diskTable.rows = [
            .init("Free", MonitorFormat.bytes(UInt64(space.free))),
            .init("Total", MonitorFormat.bytes(UInt64(space.total))),
            .init("Read", sample.diskIO.map { MonitorFormat.rate($0.read) } ?? "–"),
            .init("Write", sample.diskIO.map { MonitorFormat.rate($0.write) } ?? "–"),
        ]
    }

    private func updateBattery(_ sample: MonitorSample) {
        sections[.battery]?.isHidden = sample.battery == nil
        guard let battery = sample.battery else { return }
        let low = battery.percent <= 15 && !battery.onAC
        batteryRing.set(Double(battery.percent) / 100, color: low ? .systemRed : .systemGreen)
        batteryTable.rows = [
            .init("State", battery.isCharging ? "Charging" : battery.onAC ? "Power adapter" : "On battery"),
            battery.cycleCount.map { .init("Cycles", "\($0)") },
        ].compactMap { $0 }
    }

    @objc private func openSettings() {
        view.window?.performClose(nil)
        NexoCore.showSettings(moduleId: MonitorModule.id)
    }

    private static func ringRow(_ ring: RingGaugeView, _ table: InfoTable) -> NSView {
        let row = NSStackView(views: [ring, table])
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private static func chartRow(_ table: InfoTable, _ chart: NSView) -> NSView {
        let row = NSStackView(views: [table, chart])
        row.alignment = .centerY
        row.spacing = 10
        table.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return row
    }
}

/// A rounded card with a section title and its content views stacked full width.
final class MonitorSection: NSView {
    init(_ title: String, _ content: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        let stack = NSStackView(views: [label] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
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
