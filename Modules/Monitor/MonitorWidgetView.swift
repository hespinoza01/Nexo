import Cocoa

enum MonitorWidgetStyle: Int, CaseIterable {
    case text, bar, dot

    var title: String {
        switch self {
        case .text: return "Label + value"
        case .bar: return "Bar + value"
        case .dot: return "Dot + value"
        }
    }
}

/// Draws the enabled metrics side by side inside the monitor's status item button.
final class MonitorWidgetView: NSView {
    var metrics = [Metric]() { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var style = MonitorWidgetStyle.bar { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var sample = MonitorSample() { didSet { needsDisplay = true } }

    private static let segmentWidth: CGFloat = 40
    private static let indicatorWidth: CGFloat = 5
    private static let labelFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(max(1, metrics.count)) * Self.segmentWidth, height: NSStatusBar.system.thickness)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, metric) in metrics.enumerated() {
            drawSegment(metric, in: NSRect(x: CGFloat(index) * Self.segmentWidth, y: 0, width: Self.segmentWidth, height: bounds.height))
        }
    }

    /// Memory takes its color from the kernel pressure level only; every other metric uses the menu bar
    /// text color, with orange/red thresholds for CPU and temperature.
    static func color(_ metric: Metric, _ sample: MonitorSample) -> NSColor {
        switch metric {
        case .memory:
            switch sample.pressure.level {
            case .normal: return .systemGreen
            case .warning: return .systemYellow
            case .critical: return .systemRed
            }
        case .cpu: return threshold(sample.cpu, warning: 0.7, critical: 0.9)
        case .gpu: return threshold(sample.gpu?.device, warning: 0.7, critical: 0.9)
        case .temperature: return threshold(sample.temperature.map { $0.maximum / 100 }, warning: 0.8, critical: 0.95)
        case .battery: return sample.battery.map { $0.percent <= 15 && !$0.onAC ? .systemRed : .labelColor } ?? .labelColor
        case .network, .disk: return .labelColor
        }
    }

    static func value(_ metric: Metric, _ sample: MonitorSample) -> String {
        switch metric {
        case .cpu: return sample.cpu.map(MonitorFormat.percent) ?? "–"
        case .gpu: return sample.gpu.map { MonitorFormat.percent($0.device) } ?? "–"
        case .memory: return sample.pressure.percent.map { "\($0)%" } ?? "–"
        case .network: return sample.network.map { MonitorFormat.rate($0.download) } ?? "–"
        case .disk: return sample.diskFree.map { "\(Int(100 - Double($0.free) * 100 / Double(max(1, $0.total))))%" } ?? "–"
        case .battery: return sample.battery.map { "\($0.percent)%" } ?? "–"
        case .temperature: return sample.temperature.map { "\(Int($0.maximum))°" } ?? "–"
        }
    }

    private static func threshold(_ value: Double?, warning: Double, critical: Double) -> NSColor {
        guard let value else { return .labelColor }
        return value >= critical ? .systemRed : value >= warning ? .systemOrange : .labelColor
    }

    private func drawSegment(_ metric: Metric, in rect: NSRect) {
        let color = Self.color(metric, sample)
        var textRect = rect.insetBy(dx: 2, dy: 0)
        switch style {
        case .text: break
        case .bar:
            drawBar(sample.fraction(metric) ?? 0, color: color, in: NSRect(x: rect.minX + 2, y: 4, width: Self.indicatorWidth, height: rect.height - 8))
            textRect = textRect.divided(atDistance: Self.indicatorWidth + 3, from: .minXEdge).remainder
        case .dot:
            let dot = NSRect(x: rect.minX + 2, y: rect.midY - 3, width: 6, height: 6)
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            textRect = textRect.divided(atDistance: 9, from: .minXEdge).remainder
        }
        draw(metric.shortLabel, font: Self.labelFont, color: .secondaryLabelColor, at: NSPoint(x: textRect.minX, y: rect.midY + 1))
        let valueColor = style == .text && metric == .memory ? color : NSColor.labelColor
        draw(Self.value(metric, sample), font: Self.valueFont, color: valueColor, at: NSPoint(x: textRect.minX, y: rect.midY - 11))
    }

    private func drawBar(_ fraction: Double, color: NSColor, in rect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        let filled = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * CGFloat(max(0, min(1, fraction))))
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}

/// Small line chart of the last samples, 0–1 range.
final class SparklineView: NSView {
    var values = [Double]() { didSet { needsDisplay = true } }
    var color = NSColor.controlAccentColor

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        guard values.count > 1 else { return }
        let step = bounds.width / CGFloat(MonitorSampler.historyLength - 1)
        let offset = CGFloat(MonitorSampler.historyLength - values.count) * step
        let path = NSBezierPath()
        for (index, value) in values.enumerated() {
            let point = NSPoint(x: offset + CGFloat(index) * step, y: 2 + (bounds.height - 4) * CGFloat(max(0, min(1, value))))
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        color.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
