import Cocoa

/// Draws the enabled metrics side by side inside the monitor's status item button, each with its own
/// `MetricStyle` (label, kind, colors, width) and the global spacing/separators/font sizes.
final class MonitorWidgetView: NSView {
    var config = MonitorAppearance() { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var sample = MonitorSample() { didSet { needsDisplay = true } }
    var history = [Metric: [Double]]() { didSet { needsDisplay = true } }

    private static let indicatorWidth: CGFloat = 5
    private static let separatorWidth: CGFloat = 1

    private var metrics: [Metric] { config.menuBarMetrics }
    private var labelFont: NSFont { .systemFont(ofSize: CGFloat(config.labelSize), weight: .semibold) }
    private var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: CGFloat(config.valueSize), weight: config.boldValues ? .bold : .medium) }
    private var networkFont: NSFont {
        .monospacedDigitSystemFont(ofSize: CGFloat(max(8, config.valueSize - 1)), weight: config.boldValues ? .bold : .semibold)
    }

    override var intrinsicContentSize: NSSize {
        let widths = metrics.map(width(of:))
        let gaps = CGFloat(max(0, widths.count - 1)) * gap
        return NSSize(width: max(20, widths.reduce(0, +) + gaps + 2), height: NSStatusBar.system.thickness)
    }

    private var gap: CGFloat {
        CGFloat(config.spacing) + (config.separators ? Self.separatorWidth + CGFloat(config.spacing) : 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 2
        for (index, metric) in metrics.enumerated() {
            if index > 0 {
                if config.separators {
                    let lineX = x + CGFloat(config.spacing)
                    NSColor.tertiaryLabelColor.setFill()
                    NSRect(x: lineX, y: 4, width: Self.separatorWidth, height: bounds.height - 8).fill()
                }
                x += gap
            }
            let width = width(of: metric)
            let style = config.style(metric)
            let left = CGFloat(style.paddingLeft)
            draw(metric, in: NSRect(x: x + left, y: 0, width: width - left - CGFloat(style.paddingRight), height: bounds.height))
            x += width
        }
    }

    // MARK: Back-compat helpers (tests, popover)

    /// Default automatic color (memory: kernel pressure level only).
    static func color(_ metric: Metric, _ sample: MonitorSample) -> NSColor {
        let color = MonitorAppearance.automaticColor(metric, sample, style: MonitorAppearance.defaultStyle(metric))
        return color == .controlAccentColor ? .labelColor : color
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

    // MARK: Layout

    /// Outer width: the metric's padding plus its content.
    private func width(of metric: Metric) -> CGFloat {
        let style = config.style(metric)
        return CGFloat(style.paddingLeft + style.paddingRight) + contentWidth(metric, style)
    }

    private func contentWidth(_ metric: Metric, _ style: MetricStyle) -> CGFloat {
        let extra = CGFloat(max(0, style.extraWidth))
        if metric == .network { return networkWidth(style) + extra }
        let verticalLabel = style.showLabel ? 8 : 0 as CGFloat
        switch style.kind {
        case .line: return verticalLabel + Self.chartWidth(style.chartHistory) + extra
        case .pie: return verticalLabel + NSStatusBar.system.thickness - 4 + extra
        case .text: return textColumnWidth(metric, style) + extra
        case .bar: return Self.indicatorWidth + 3 + textColumnWidth(metric, style) + extra
        case .dot: return 9 + textColumnWidth(metric, style) + extra
        }
    }

    static func chartWidth(_ history: Int) -> CGFloat {
        switch history {
        case ..<45: return 24
        case ..<75: return 32
        case ..<105: return 42
        default: return 52
        }
    }

    /// Wide enough for the label and the widest value ("100%"), so the item doesn't jitter.
    private func textColumnWidth(_ metric: Metric, _ style: MetricStyle) -> CGFloat {
        let widest = metric == .temperature ? "100°" : "100%"
        var width = size(widest, valueFont).width
        if style.showLabel { width = max(width, size(config.label(metric), labelFont).width) }
        return ceil(width) + 2
    }

    private func networkWidth(_ style: MetricStyle) -> CGFloat {
        let arrow = style.arrowStyle.symbols.map { ceil(size($0.up, networkFont).width) + 3 } ?? 0
        let value = ceil(size("999 KB/s", networkFont).width)
        let column = arrow + value + 2
        let label = style.showLabel ? 8 : 0 as CGFloat
        switch style.networkLayout {
        case .twoRows, .downloadOnly, .uploadOnly: return label + column
        case .oneRow: return label + column * 2 + 4
        }
    }

    // MARK: Drawing

    private func draw(_ metric: Metric, in rect: NSRect) {
        let style = config.style(metric)
        if metric == .network { return drawNetwork(style, in: rect) }
        let color = config.color(metric, sample)
        var rect = rect
        switch style.kind {
        case .text:
            drawText(metric, style, color: color, in: rect)
        case .bar:
            drawBar(sample.fraction(metric) ?? 0, color: color, in: NSRect(x: rect.minX, y: 4, width: Self.indicatorWidth, height: rect.height - 8))
            rect = rect.divided(atDistance: Self.indicatorWidth + 3, from: .minXEdge).remainder
            drawText(metric, style, color: color, in: rect)
        case .dot:
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX, y: rect.midY - 3, width: 6, height: 6)).fill()
            rect = rect.divided(atDistance: 9, from: .minXEdge).remainder
            drawText(metric, style, color: color, in: rect)
        case .line:
            rect = drawVerticalLabel(metric, style, in: rect)
            drawLine(history[metric] ?? [], count: style.chartHistory, color: color, in: rect)
        case .pie:
            rect = drawVerticalLabel(metric, style, in: rect)
            drawPie(sample.fraction(metric) ?? 0, color: color, in: rect)
        }
    }

    private func drawText(_ metric: Metric, _ style: MetricStyle, color: NSColor, in rect: NSRect) {
        let valueColor = style.colorizeValue ? color : NSColor.labelColor
        let value = Self.value(metric, sample)
        guard style.showLabel else {
            let height = size(value, valueFont).height
            draw(value, font: valueFont, color: valueColor, at: NSPoint(x: rect.minX, y: rect.midY - height / 2))
            return
        }
        draw(config.label(metric), font: labelFont, color: .secondaryLabelColor, at: NSPoint(x: rect.minX, y: rect.midY + 1))
        let valueHeight = size(value, valueFont).height
        draw(value, font: valueFont, color: valueColor, at: NSPoint(x: rect.minX, y: rect.midY - valueHeight + 2))
    }

    /// Stats-style stacked letters (up to 3) on the left of a chart. Returns the remaining rect.
    private func drawVerticalLabel(_ metric: Metric, _ style: MetricStyle, in rect: NSRect) -> NSRect {
        guard style.showLabel else { return rect }
        let letters = Array(config.label(metric).uppercased().prefix(3))
        let font = labelFont
        let lineHeight = (rect.height - 4) / 3
        for (index, letter) in letters.enumerated() {
            let text = String(letter)
            let width = size(text, font).width
            let y = rect.maxY - 2 - lineHeight * CGFloat(index + 1) + (lineHeight - 8) / 2
            draw(text, font: font, color: .secondaryLabelColor, at: NSPoint(x: rect.minX + (6 - width) / 2, y: y))
        }
        return rect.divided(atDistance: 8, from: .minXEdge).remainder
    }

    private func drawLine(_ values: [Double], count: Int, color: NSColor, in rect: NSRect) {
        let box = rect.insetBy(dx: 0, dy: 3)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
        let points = values.suffix(max(2, count))
        guard points.count > 1 else { return }
        let step = box.width / CGFloat(max(1, count - 1))
        let offset = CGFloat(count - points.count) * step
        let path = NSBezierPath()
        for (index, value) in points.enumerated() {
            let point = NSPoint(x: box.minX + offset + CGFloat(index) * step, y: box.minY + 1 + (box.height - 2) * CGFloat(value.unit))
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: box.maxX, y: box.minY))
        fill.line(to: NSPoint(x: box.minX + offset, y: box.minY))
        fill.close()
        color.withAlphaComponent(0.3).setFill()
        fill.fill()
        color.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawPie(_ fraction: Double, color: NSColor, in rect: NSRect) {
        let diameter = min(rect.width, rect.height - 4)
        let circle = NSRect(x: rect.minX, y: rect.midY - diameter / 2, width: diameter, height: diameter)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(ovalIn: circle).fill()
        guard fraction > 0 else { return }
        let center = NSPoint(x: circle.midX, y: circle.midY)
        let slice = NSBezierPath()
        slice.move(to: center)
        slice.appendArc(withCenter: center, radius: diameter / 2, startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction.unit), clockwise: true)
        slice.close()
        color.setFill()
        slice.fill()
    }

    private func drawNetwork(_ style: MetricStyle, in rect: NSRect) {
        var rect = rect
        if style.showLabel { rect = drawVerticalLabel(.network, style, in: rect) }
        let up = NSColor(hex: style.uploadColor) ?? .systemRed
        let down = NSColor(hex: style.downloadColor) ?? .systemBlue
        let rows: [(symbol: String?, value: Double?, color: NSColor)] = [
            (style.arrowStyle.symbols?.up, sample.network?.upload, up),
            (style.arrowStyle.symbols?.down, sample.network?.download, down),
        ]
        let lineHeight = size("0", networkFont).height
        switch style.networkLayout {
        case .twoRows:
            drawRate(rows[0], style, in: NSRect(x: rect.minX, y: rect.midY - 1, width: rect.width, height: lineHeight))
            drawRate(rows[1], style, in: NSRect(x: rect.minX, y: rect.midY - lineHeight + 1, width: rect.width, height: lineHeight))
        case .oneRow:
            let half = (rect.width - 4) / 2
            let y = rect.midY - lineHeight / 2
            drawRate(rows[1], style, in: NSRect(x: rect.minX, y: y, width: half, height: lineHeight))
            drawRate(rows[0], style, in: NSRect(x: rect.minX + half + 4, y: y, width: half, height: lineHeight))
        case .downloadOnly, .uploadOnly:
            let row = style.networkLayout == .downloadOnly ? rows[1] : rows[0]
            drawRate(row, style, in: NSRect(x: rect.minX, y: rect.midY - lineHeight / 2, width: rect.width, height: lineHeight))
        }
    }

    private func drawRate(_ row: (symbol: String?, value: Double?, color: NSColor), _ style: MetricStyle, in rect: NSRect) {
        let active = (row.value ?? 0) >= 1024
        if let symbol = row.symbol {
            draw(symbol, font: networkFont, color: active ? row.color : .secondaryLabelColor, at: NSPoint(x: rect.minX, y: rect.minY))
        }
        let text = row.value.map(MonitorFormat.spacedRate) ?? "–"
        let width = size(text, networkFont).width
        let color = style.colorizeValue && active ? row.color : NSColor.labelColor
        draw(text, font: networkFont, color: color, at: NSPoint(x: rect.maxX - width, y: rect.minY))
    }

    private func drawBar(_ fraction: Double, color: NSColor, in rect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        let filled = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * CGFloat(fraction.unit))
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func size(_ text: String, _ font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}

extension Double {
    /// NaN-safe 0–1 clamp for drawing.
    var unit: Double { isFinite ? clamped(0, 1) : 0 }
}

/// Small line chart of the last samples, 0–1 range.
final class SparklineView: NSView {
    var values = [Double]() { didSet { needsDisplay = true } }
    var color = NSColor.controlAccentColor
    var capacity = 60 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let points = values.suffix(max(2, capacity))
        guard points.count > 1 else { return }
        let step = bounds.width / CGFloat(max(1, capacity - 1))
        let offset = CGFloat(capacity - points.count) * step
        let path = NSBezierPath()
        for (index, value) in points.enumerated() {
            let point = NSPoint(x: offset + CGFloat(index) * step, y: 2 + (bounds.height - 4) * CGFloat(value.unit))
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        color.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
