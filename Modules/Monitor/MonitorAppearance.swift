import Cocoa

/// How a metric is drawn in the menu bar.
enum WidgetKind: String, Codable, CaseIterable {
    case text, bar, line, pie, dot

    var title: String {
        switch self {
        case .text: return L("Label + value")
        case .bar: return L("Bar")
        case .line: return L("Line chart")
        case .pie: return L("Pie")
        case .dot: return L("Dot + value")
        }
    }
}

/// Where a metric's color comes from. `automatic` follows thresholds (memory: kernel pressure level).
enum ColorMode: String, Codable, CaseIterable {
    case automatic, accent, monochrome, custom

    var title: String {
        switch self {
        case .automatic: return L("Automatic (by load)")
        case .accent: return L("System accent")
        case .monochrome: return L("Monochrome")
        case .custom: return L("Custom")
        }
    }
}

enum NetworkLayout: String, Codable, CaseIterable {
    case twoRows, oneRow, downloadOnly, uploadOnly

    var title: String {
        switch self {
        case .twoRows: return L("Two rows")
        case .oneRow: return L("One row")
        case .downloadOnly: return L("Download only")
        case .uploadOnly: return L("Upload only")
        }
    }
}

enum ArrowStyle: String, Codable, CaseIterable {
    case arrows, triangles, letters, none

    var title: String {
        switch self {
        case .arrows: return "↑ ↓"
        case .triangles: return "▲ ▼"
        case .letters: return "U D"
        case .none: return L("None")
        }
    }

    var symbols: (up: String, down: String)? {
        switch self {
        case .arrows: return ("↑", "↓")
        case .triangles: return ("▲", "▼")
        case .letters: return ("U", "D")
        case .none: return nil
        }
    }
}

/// Per-metric menu bar widget settings. Every field has a default so older JSON keeps decoding.
struct MetricStyle: Codable, Equatable {
    var enabled = false
    var label: String?
    var showLabel = true
    var kind = WidgetKind.text
    var colorMode = ColorMode.automatic
    var customColor = "#0A84FF"
    /// Color the value text too, not just the indicator.
    var colorizeValue = false
    /// 0–1 thresholds for `automatic` (ignored by memory, which uses the kernel level).
    var warning = 0.7
    var critical = 0.9
    /// Extra width in points, for alignment with neighbours.
    var extraWidth = 0.0
    /// Space before/after this metric in the menu bar, on top of the global spacing.
    var paddingLeft = 0.0
    var paddingRight = 0.0
    var chartHistory = 30
    var networkLayout = NetworkLayout.twoRows
    var arrowStyle = ArrowStyle.arrows
    var uploadColor = "#FF453A"
    var downloadColor = "#0A84FF"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MetricStyle()
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? d.enabled
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        showLabel = ((try? c.decodeIfPresent(Bool.self, forKey: .showLabel)) ?? nil) ?? d.showLabel
        kind = ((try? c.decodeIfPresent(WidgetKind.self, forKey: .kind)) ?? nil) ?? d.kind
        colorMode = ((try? c.decodeIfPresent(ColorMode.self, forKey: .colorMode)) ?? nil) ?? d.colorMode
        customColor = ((try? c.decodeIfPresent(String.self, forKey: .customColor)) ?? nil) ?? d.customColor
        colorizeValue = ((try? c.decodeIfPresent(Bool.self, forKey: .colorizeValue)) ?? nil) ?? d.colorizeValue
        warning = ((try? c.decodeIfPresent(Double.self, forKey: .warning)) ?? nil) ?? d.warning
        critical = ((try? c.decodeIfPresent(Double.self, forKey: .critical)) ?? nil) ?? d.critical
        extraWidth = ((try? c.decodeIfPresent(Double.self, forKey: .extraWidth)) ?? nil) ?? d.extraWidth
        paddingLeft = ((try? c.decodeIfPresent(Double.self, forKey: .paddingLeft)) ?? nil) ?? d.paddingLeft
        paddingRight = ((try? c.decodeIfPresent(Double.self, forKey: .paddingRight)) ?? nil) ?? d.paddingRight
        chartHistory = ((try? c.decodeIfPresent(Int.self, forKey: .chartHistory)) ?? nil) ?? d.chartHistory
        networkLayout = ((try? c.decodeIfPresent(NetworkLayout.self, forKey: .networkLayout)) ?? nil) ?? d.networkLayout
        arrowStyle = ((try? c.decodeIfPresent(ArrowStyle.self, forKey: .arrowStyle)) ?? nil) ?? d.arrowStyle
        uploadColor = ((try? c.decodeIfPresent(String.self, forKey: .uploadColor)) ?? nil) ?? d.uploadColor
        downloadColor = ((try? c.decodeIfPresent(String.self, forKey: .downloadColor)) ?? nil) ?? d.downloadColor
    }
}

enum PopoverDensity: String, Codable, CaseIterable {
    case compact, regular, spacious

    var title: String { L(rawValue.capitalized) }
    var sectionSpacing: CGFloat { self == .compact ? 4 : self == .regular ? 6 : 10 }
    var rowSpacing: CGFloat { self == .compact ? 1 : self == .regular ? 2 : 4 }
    var padding: CGFloat { self == .compact ? 8 : self == .regular ? 10 : 14 }
}

/// Detail popover settings.
struct PopoverStyle: Codable, Equatable {
    var width = 300.0
    var density = PopoverDensity.regular
    /// Temperature is folded into the CPU section unless shown on its own.
    var hidden = [Metric.temperature.rawValue]
    var showCoreBars = true
    var showCharts = true
    var topProcesses = 5
    var systemColor = "#FF453A"
    var userColor = "#0A84FF"
    var efficiencyColor = "#40C8E0"
    var performanceColor = "#5E5CE6"
    var appColor = "#0A84FF"
    var wiredColor = "#FF9F0A"
    var compressedColor = "#FF375F"
    var uploadColor = "#FF453A"
    var downloadColor = "#0A84FF"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PopoverStyle()
        width = ((try? c.decodeIfPresent(Double.self, forKey: .width)) ?? nil) ?? d.width
        density = ((try? c.decodeIfPresent(PopoverDensity.self, forKey: .density)) ?? nil) ?? d.density
        hidden = ((try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? nil) ?? d.hidden
        showCoreBars = ((try? c.decodeIfPresent(Bool.self, forKey: .showCoreBars)) ?? nil) ?? d.showCoreBars
        showCharts = ((try? c.decodeIfPresent(Bool.self, forKey: .showCharts)) ?? nil) ?? d.showCharts
        topProcesses = ((try? c.decodeIfPresent(Int.self, forKey: .topProcesses)) ?? nil) ?? d.topProcesses
        systemColor = ((try? c.decodeIfPresent(String.self, forKey: .systemColor)) ?? nil) ?? d.systemColor
        userColor = ((try? c.decodeIfPresent(String.self, forKey: .userColor)) ?? nil) ?? d.userColor
        efficiencyColor = ((try? c.decodeIfPresent(String.self, forKey: .efficiencyColor)) ?? nil) ?? d.efficiencyColor
        performanceColor = ((try? c.decodeIfPresent(String.self, forKey: .performanceColor)) ?? nil) ?? d.performanceColor
        appColor = ((try? c.decodeIfPresent(String.self, forKey: .appColor)) ?? nil) ?? d.appColor
        wiredColor = ((try? c.decodeIfPresent(String.self, forKey: .wiredColor)) ?? nil) ?? d.wiredColor
        compressedColor = ((try? c.decodeIfPresent(String.self, forKey: .compressedColor)) ?? nil) ?? d.compressedColor
        uploadColor = ((try? c.decodeIfPresent(String.self, forKey: .uploadColor)) ?? nil) ?? d.uploadColor
        downloadColor = ((try? c.decodeIfPresent(String.self, forKey: .downloadColor)) ?? nil) ?? d.downloadColor
    }
}

/// Alerts posted as user notifications.
struct MonitorAlerts: Codable, Equatable {
    var memoryPressure = false
    var cpuSustained = false
    var cpuThreshold = 0.9
    var cpuSeconds = 60.0
    var lowDisk = false
    var lowDiskFraction = 0.1

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorAlerts()
        memoryPressure = ((try? c.decodeIfPresent(Bool.self, forKey: .memoryPressure)) ?? nil) ?? d.memoryPressure
        cpuSustained = ((try? c.decodeIfPresent(Bool.self, forKey: .cpuSustained)) ?? nil) ?? d.cpuSustained
        cpuThreshold = ((try? c.decodeIfPresent(Double.self, forKey: .cpuThreshold)) ?? nil) ?? d.cpuThreshold
        cpuSeconds = ((try? c.decodeIfPresent(Double.self, forKey: .cpuSeconds)) ?? nil) ?? d.cpuSeconds
        lowDisk = ((try? c.decodeIfPresent(Bool.self, forKey: .lowDisk)) ?? nil) ?? d.lowDisk
        lowDiskFraction = ((try? c.decodeIfPresent(Double.self, forKey: .lowDiskFraction)) ?? nil) ?? d.lowDiskFraction
    }
}

/// Everything about how the monitor looks, persisted as one JSON blob and shareable as a preset.
struct MonitorAppearance: Codable, Equatable {
    var order = Metric.allCases.map(\.rawValue)
    var styles = [String: MetricStyle]()
    /// Gap between metrics in the menu bar, in points.
    var spacing = 4.0
    var separators = false
    var labelSize = 7.0
    var valueSize = 10.0
    var boldValues = false
    var popover = PopoverStyle()
    var alerts = MonitorAlerts()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorAppearance()
        order = ((try? c.decodeIfPresent([String].self, forKey: .order)) ?? nil) ?? d.order
        styles = ((try? c.decodeIfPresent([String: MetricStyle].self, forKey: .styles)) ?? nil) ?? d.styles
        spacing = ((try? c.decodeIfPresent(Double.self, forKey: .spacing)) ?? nil) ?? d.spacing
        separators = ((try? c.decodeIfPresent(Bool.self, forKey: .separators)) ?? nil) ?? d.separators
        labelSize = ((try? c.decodeIfPresent(Double.self, forKey: .labelSize)) ?? nil) ?? d.labelSize
        valueSize = ((try? c.decodeIfPresent(Double.self, forKey: .valueSize)) ?? nil) ?? d.valueSize
        boldValues = ((try? c.decodeIfPresent(Bool.self, forKey: .boldValues)) ?? nil) ?? d.boldValues
        popover = ((try? c.decodeIfPresent(PopoverStyle.self, forKey: .popover)) ?? nil) ?? d.popover
        alerts = ((try? c.decodeIfPresent(MonitorAlerts.self, forKey: .alerts)) ?? nil) ?? d.alerts
        self = sanitized()
    }

    /// Clamps every number to its supported range and drops duplicate/unknown order entries, so a
    /// hand-edited or imported JSON can't break drawing.
    func sanitized() -> MonitorAppearance {
        var a = self
        var seen = Set<String>()
        a.order = order.filter { Metric(rawValue: $0) != nil && seen.insert($0).inserted }
        a.spacing = spacing.finiteClamped(0, 16)
        a.labelSize = labelSize.finiteClamped(6, 10)
        a.valueSize = valueSize.finiteClamped(8, 14)
        for (key, style) in styles {
            var s = style
            s.chartHistory = min(120, max(10, style.chartHistory))
            s.extraWidth = style.extraWidth.finiteClamped(0, 20)
            s.paddingLeft = style.paddingLeft.finiteClamped(0, 30)
            s.paddingRight = style.paddingRight.finiteClamped(0, 30)
            s.critical = style.critical.finiteClamped(0.05, 1)
            s.warning = min(style.warning.finiteClamped(0, 1), s.critical)
            if let label = s.label { s.label = String(label.prefix(8)) }
            a.styles[key] = s
        }
        a.popover.width = popover.width.finiteClamped(260, 420)
        a.popover.topProcesses = min(20, max(0, popover.topProcesses))
        a.alerts.cpuThreshold = alerts.cpuThreshold.finiteClamped(0.1, 1)
        a.alerts.cpuSeconds = alerts.cpuSeconds.finiteClamped(5, 3600)
        a.alerts.lowDiskFraction = alerts.lowDiskFraction.finiteClamped(0.01, 0.5)
        return a
    }

    /// A preset restyles the menu bar and popover layout; alerts, popover colors, hidden sections,
    /// width, process count and custom label texts are the user's and are kept.
    func applying(preset: MonitorAppearance) -> MonitorAppearance {
        var a = preset
        a.alerts = alerts
        a.popover.hidden = popover.hidden
        a.popover.width = popover.width
        a.popover.topProcesses = popover.topProcesses
        a.popover.systemColor = popover.systemColor
        a.popover.userColor = popover.userColor
        a.popover.efficiencyColor = popover.efficiencyColor
        a.popover.performanceColor = popover.performanceColor
        a.popover.appColor = popover.appColor
        a.popover.wiredColor = popover.wiredColor
        a.popover.compressedColor = popover.compressedColor
        a.popover.uploadColor = popover.uploadColor
        a.popover.downloadColor = popover.downloadColor
        for metric in Metric.allCases {
            let label = style(metric).label
            a.update(metric) { $0.label = label }
        }
        return a
    }

    /// Every metric in the user's order; metrics added in later versions go last, unknown ids are dropped.
    var orderedMetrics: [Metric] {
        let stored = order.compactMap(Metric.init(rawValue:))
        return stored + Metric.allCases.filter { !stored.contains($0) }
    }

    var menuBarMetrics: [Metric] { orderedMetrics.filter { style($0).enabled } }

    func style(_ metric: Metric) -> MetricStyle {
        styles[metric.rawValue] ?? Self.defaultStyle(metric)
    }

    mutating func update(_ metric: Metric, _ change: (inout MetricStyle) -> Void) {
        var style = style(metric)
        change(&style)
        styles[metric.rawValue] = style
    }

    func label(_ metric: Metric) -> String {
        let custom = style(metric).label?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? metric.shortLabel : custom
    }

    func isSectionVisible(_ metric: Metric) -> Bool { !popover.hidden.contains(metric.rawValue) }

    static func defaultStyle(_ metric: Metric) -> MetricStyle {
        var style = MetricStyle()
        style.enabled = metric == .cpu || metric == .memory
        style.showLabel = metric != .network
        if metric == .temperature {
            style.warning = 0.8
            style.critical = 0.95
        }
        return style
    }

    // MARK: Presets

    static let stats: MonitorAppearance = {
        var a = MonitorAppearance()
        a.order = [Metric.network, .gpu, .cpu, .memory, .disk, .battery, .temperature].map(\.rawValue)
        for metric in [Metric.network, .gpu, .cpu, .memory] { a.update(metric) { $0.enabled = true } }
        a.update(.memory) { $0.colorizeValue = true }
        a.spacing = 4
        return a
    }()

    static let minimal: MonitorAppearance = {
        var a = stats
        for metric in Metric.allCases { a.update(metric) { $0.showLabel = false; $0.colorMode = .monochrome; $0.colorizeValue = false } }
        a.update(.memory) { $0.kind = .dot; $0.colorMode = .automatic }
        a.update(.network) { $0.networkLayout = .oneRow; $0.arrowStyle = .triangles }
        a.valueSize = 11
        a.spacing = 6
        a.popover.density = .compact
        a.popover.showCharts = false
        return a
    }()

    static let graphs: MonitorAppearance = {
        var a = stats
        a.update(.cpu) { $0.kind = .line; $0.colorMode = .accent }
        a.update(.gpu) { $0.kind = .bar }
        a.update(.memory) { $0.kind = .pie }
        a.separators = true
        a.popover.showCoreBars = false
        return a
    }()

    static let colorful: MonitorAppearance = {
        var a = stats
        a.update(.cpu) { $0.kind = .bar; $0.colorMode = .custom; $0.customColor = "#30D158"; $0.colorizeValue = true }
        a.update(.gpu) { $0.kind = .bar; $0.colorMode = .custom; $0.customColor = "#BF5AF2"; $0.colorizeValue = true }
        a.update(.memory) { $0.kind = .bar; $0.colorizeValue = true }
        a.update(.network) { $0.arrowStyle = .triangles }
        a.boldValues = true
        a.separators = true
        return a
    }()

    static let presets: [(name: String, appearance: MonitorAppearance)] = [
        ("Classic", stats), ("Minimal", minimal), ("Graphs", graphs), ("Colorful", colorful),
    ]
}

/// Loads, saves and broadcasts the appearance. Migrates the pre-JSON keys (`monitor.metrics`,
/// `monitor.order`, `monitor.style`) the first time.
final class MonitorAppearanceStore: ObservableObject {
    static let key = "monitor.appearance"
    private let defaults: UserDefaults

    @Published var appearance: MonitorAppearance {
        didSet {
            guard appearance != oldValue else { return }
            save()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode(MonitorAppearance.self, from: data) {
            appearance = stored
        } else {
            appearance = Self.migrated(defaults).sanitized()
        }
    }

    func export() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(appearance)
    }

    func importData(_ data: Data) throws {
        appearance = try JSONDecoder().decode(MonitorAppearance.self, from: data).sanitized()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func migrated(_ defaults: UserDefaults) -> MonitorAppearance {
        var a = MonitorAppearance()
        if let order = defaults.stringArray(forKey: "monitor.order") { a.order = order }
        let enabled = defaults.stringArray(forKey: "monitor.metrics") ?? [Metric.cpu, .memory].map(\.rawValue)
        let legacyKind: WidgetKind = [0: .text, 1: .bar, 2: .dot][defaults.integer(forKey: "monitor.style")] ?? .text
        for metric in Metric.allCases {
            a.update(metric) {
                $0.enabled = enabled.contains(metric.rawValue)
                if metric != .network { $0.kind = legacyKind }
            }
        }
        return a
    }
}

extension Double {
    /// Clamped to the range; NaN/infinite become the lower bound.
    func finiteClamped(_ lower: Double, _ upper: Double) -> Double {
        isFinite ? Swift.min(Swift.max(self, lower), upper) : lower
    }
}

extension MonitorAppearance {
    /// Resolved color for a metric's indicator. Memory in automatic mode follows the kernel pressure
    /// level only; other metrics compare their load against the style's thresholds.
    func color(_ metric: Metric, _ sample: MonitorSample) -> NSColor {
        let style = style(metric)
        switch style.colorMode {
        case .accent: return .controlAccentColor
        case .monochrome: return .labelColor
        case .custom: return NSColor(hex: style.customColor) ?? .controlAccentColor
        case .automatic: return Self.automaticColor(metric, sample, style: style)
        }
    }

    static func automaticColor(_ metric: Metric, _ sample: MonitorSample, style: MetricStyle) -> NSColor {
        switch metric {
        case .memory:
            switch sample.pressure.level {
            case .normal: return .systemGreen
            case .warning: return .systemYellow
            case .critical: return .systemRed
            }
        case .battery:
            guard let battery = sample.battery else { return .labelColor }
            return battery.percent <= 15 && !battery.onAC ? .systemRed : battery.percent <= 30 && !battery.onAC ? .systemOrange : .systemGreen
        case .network:
            return .controlAccentColor
        default:
            guard let value = sample.fraction(metric) else { return .controlAccentColor }
            return value >= style.critical ? .systemRed : value >= style.warning ? .systemOrange : .controlAccentColor
        }
    }
}
