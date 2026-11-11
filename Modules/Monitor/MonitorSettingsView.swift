import SwiftUI
import ShortcutRecorder
import UniformTypeIdentifiers

/// Monitor settings: live preview, presets, per-metric menu bar widget editor (drag to reorder),
/// global spacing/fonts, popover layout/colors, alerts and general options.
struct MonitorSettingsView: View {
    @ObservedObject var store: MonitorAppearanceStore
    @ObservedObject var live: MonitorLiveModel
    let module: MonitorModule
    @State private var selected: Metric = .cpu
    @State private var interval: TimeInterval = 2
    @State private var tab = Tab.menuBar
    @State private var message: String?

    enum Tab: String, CaseIterable {
        case menuBar = "Menu bar", popover = "Popover", alerts = "Alerts", general = "General"
    }

    private var appearance: Binding<MonitorAppearance> { $store.appearance }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
            presets
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch tab {
                case .menuBar: menuBarTab
                case .popover: popoverTab
                case .alerts: alertsTab
                case .general: generalTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 520, idealHeight: 620)
        .onAppear {
            MonitorLiveModel.previewVisible = true
            interval = module.interval
        }
        .onDisappear { MonitorLiveModel.previewVisible = false }
    }

    // MARK: Header

    private var preview: some View {
        HStack {
            Spacer()
            WidgetPreview(config: store.appearance, sample: live.sample, history: live.history)
                .fixedSize()
            Spacer()
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .help("Live preview of the menu bar widget")
    }

    private var presets: some View {
        HStack(spacing: 8) {
            Menu("Presets") {
                ForEach(MonitorAppearance.presets.map(\.name), id: \.self) { name in
                    SwiftUI.Button(name) { applyPreset(name) }
                }
                Divider()
                SwiftUI.Button("Reset to defaults") { store.appearance = store.appearance.applying(preset: MonitorAppearance()) }
            }
            .fixedSize()
            SwiftUI.Button("Import…", action: importPreset)
            SwiftUI.Button("Export…", action: exportPreset)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Menu bar

    private var menuBarTab: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Metrics").font(.headline)
                List(selection: Binding(get: { selected }, set: { selected = $0 ?? selected })) {
                    ForEach(store.appearance.orderedMetrics, id: \.self) { metric in
                        HStack {
                            Toggle("", isOn: styleBinding(metric, \.enabled)).labelsHidden()
                            Text(metric.title)
                            Spacer()
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        }
                        .tag(metric)
                    }
                    .onMove { from, to in
                        var order = store.appearance.orderedMetrics
                        order.move(fromOffsets: from, toOffset: to)
                        store.appearance.order = order.map(\.rawValue)
                    }
                }
                .frame(width: 190, height: 220)
                Text("Drag to reorder. The order applies to the menu bar and the popover.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 190, alignment: .leading)
            }
            Form {
                metricEditor(selected)
                Section("All metrics") {
                    slider("Spacing", appearance.spacing, 0...16, step: 1, format: "%.0f pt")
                    Toggle("Separators between metrics", isOn: appearance.separators)
                    slider("Label size", appearance.labelSize, 6...10, step: 0.5, format: "%.1f pt")
                    slider("Value size", appearance.valueSize, 8...14, step: 0.5, format: "%.1f pt")
                    Toggle("Bold values", isOn: appearance.boldValues)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func metricEditor(_ metric: Metric) -> some View {
        let style = store.appearance.style(metric)
        Section(metric.title) {
            Toggle("Show in menu bar", isOn: styleBinding(metric, \.enabled))
            SwiftUI.TextField("Label", text: labelBinding(metric), prompt: Text(metric.shortLabel))
            Toggle("Show label", isOn: styleBinding(metric, \.showLabel))
            if metric == .network {
                Picker("Layout", selection: styleBinding(metric, \.networkLayout)) {
                    ForEach(NetworkLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Arrows", selection: styleBinding(metric, \.arrowStyle)) {
                    ForEach(ArrowStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                colorRow("Upload color", hexBinding(metric, \.uploadColor))
                colorRow("Download color", hexBinding(metric, \.downloadColor))
                Toggle("Color values while transferring", isOn: styleBinding(metric, \.colorizeValue))
            } else {
                Picker("Widget", selection: styleBinding(metric, \.kind)) {
                    ForEach(WidgetKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Color", selection: styleBinding(metric, \.colorMode)) {
                    ForEach(ColorMode.allCases, id: \.self) { Text(colorModeTitle($0, metric)).tag($0) }
                }
                if style.colorMode == .custom {
                    colorRow("Custom color", hexBinding(metric, \.customColor))
                }
                if [.text, .bar, .dot].contains(style.kind) {
                    Toggle("Color the value too", isOn: styleBinding(metric, \.colorizeValue))
                }
                if style.kind == .line {
                    Picker("Chart history", selection: styleBinding(metric, \.chartHistory)) {
                        ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) samples").tag($0) }
                    }
                }
                if style.colorMode == .automatic, ![.memory, .battery].contains(metric) {
                    slider("Warning at", styleBinding(metric, \.warning), 0.3...0.95, step: 0.05, format: "%.0f%%", scale: 100)
                    slider("Critical at", styleBinding(metric, \.critical), 0.4...1, step: 0.05, format: "%.0f%%", scale: 100)
                }
            }
            slider("Space left", styleBinding(metric, \.paddingLeft), 0...30, step: 1, format: "%.0f pt")
            slider("Space right", styleBinding(metric, \.paddingRight), 0...30, step: 1, format: "%.0f pt")
            slider("Extra width", styleBinding(metric, \.extraWidth), 0...20, step: 1, format: "%.0f pt")
        }
    }

    private func colorModeTitle(_ mode: ColorMode, _ metric: Metric) -> String {
        guard mode == .automatic else { return mode.title }
        switch metric {
        case .memory: return "Automatic (memory pressure)"
        case .battery: return "Automatic (charge level)"
        default: return mode.title
        }
    }

    // MARK: Popover

    private var popoverTab: some View {
        Form {
            Section("Layout") {
                slider("Width", appearance.popover.width, 260...420, step: 10, format: "%.0f pt")
                Picker("Density", selection: appearance.popover.density) {
                    ForEach(PopoverDensity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Per-core bars", isOn: appearance.popover.showCoreBars)
                Toggle("History charts", isOn: appearance.popover.showCharts)
                Picker("Top processes", selection: appearance.popover.topProcesses) {
                    ForEach([0, 3, 5, 8, 10], id: \.self) { Text($0 == 0 ? "Hidden" : "\($0)").tag($0) }
                }
            }
            Section("Sections (order follows the Menu bar tab)") {
                ForEach(store.appearance.orderedMetrics, id: \.self) { metric in
                    Toggle(metric.title, isOn: Binding(
                        get: { store.appearance.isSectionVisible(metric) },
                        set: { visible in
                            store.appearance.popover.hidden.removeAll { $0 == metric.rawValue }
                            if !visible { store.appearance.popover.hidden.append(metric.rawValue) }
                        }))
                }
            }
            Section("Colors") {
                colorRow("CPU system", appearance.popover.systemColor)
                colorRow("CPU user", appearance.popover.userColor)
                colorRow("Efficiency cores", appearance.popover.efficiencyColor)
                colorRow("Performance cores", appearance.popover.performanceColor)
                colorRow("App memory", appearance.popover.appColor)
                colorRow("Wired memory", appearance.popover.wiredColor)
                colorRow("Compressed memory", appearance.popover.compressedColor)
                colorRow("Upload", appearance.popover.uploadColor)
                colorRow("Download", appearance.popover.downloadColor)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Alerts

    private var alertsTab: some View {
        Form {
            Section {
                Toggle("Memory pressure reaches warning or critical", isOn: appearance.alerts.memoryPressure)
                Toggle("CPU stays high", isOn: appearance.alerts.cpuSustained)
                if store.appearance.alerts.cpuSustained {
                    slider("Above", appearance.alerts.cpuThreshold, 0.5...1, step: 0.05, format: "%.0f%%", scale: 100)
                    slider("For", appearance.alerts.cpuSeconds, 10...300, step: 10, format: "%.0f s")
                }
                Toggle("Startup disk almost full", isOn: appearance.alerts.lowDisk)
                if store.appearance.alerts.lowDisk {
                    slider("Free space below", appearance.alerts.lowDiskFraction, 0.02...0.3, step: 0.01, format: "%.0f%%", scale: 100)
                }
            } footer: {
                Text("Each alert fires once and re-arms when the condition clears. macOS asks once for notification permission. Presets don't change alerts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section {
                Picker("Update every", selection: Binding(get: { interval }, set: { interval = $0; module.interval = $0 })) {
                    ForEach(MonitorModule.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                LabeledContent("Open popover shortcut") {
                    ShortcutField(key: MonitorModule.Key.shortcut) { module.registerShortcut($0) }
                }
            } footer: {
                Text("Memory shows the kernel's memory pressure, the same value and color as Activity Monitor. Used/wired/compressed memory is in the popover. Temperatures use a private macOS API and may be missing on some versions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Helpers

    private func styleBinding<T>(_ metric: Metric, _ keyPath: WritableKeyPath<MetricStyle, T>) -> Binding<T> {
        Binding(get: { store.appearance.style(metric)[keyPath: keyPath] },
                set: { value in store.appearance.update(metric) { $0[keyPath: keyPath] = value } })
    }

    private func applyPreset(_ name: String) {
        guard let preset = MonitorAppearance.presets.first(where: { $0.name == name }) else { return }
        store.appearance = store.appearance.applying(preset: preset.appearance)
    }

    private func labelBinding(_ metric: Metric) -> Binding<String> {
        Binding(get: { store.appearance.style(metric).label ?? "" },
                set: { (value: String) in
                    store.appearance.update(metric) { style in style.label = value.isEmpty ? nil : value }
                })
    }

    private func hexBinding(_ metric: Metric, _ keyPath: WritableKeyPath<MetricStyle, String>) -> Binding<String> {
        styleBinding(metric, keyPath)
    }

    private func colorRow(_ title: String, _ hex: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .controlAccentColor) },
            set: { hex.wrappedValue = NSColor($0).hexString }), supportsOpacity: false)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, format: String, scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 160)
                Text(String(format: format, value.wrappedValue * scale)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Double>, step: Double, format: String) -> some View {
        slider(title, Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }), range, step: step, format: format)
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importData(Data(contentsOf: url))
            message = "Imported \(url.lastPathComponent)"
        } catch {
            message = "Couldn't import: \(error.localizedDescription)"
        }
    }

    private func exportPreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Nexo Monitor.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export().write(to: url, options: .atomic)
            message = "Exported \(url.lastPathComponent)"
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// The real menu bar widget, drawn with the live sample.
private struct WidgetPreview: NSViewRepresentable {
    let config: MonitorAppearance
    let sample: MonitorSample
    let history: [Metric: [Double]]

    func makeNSView(context: Context) -> MonitorWidgetView { MonitorWidgetView() }

    func updateNSView(_ view: MonitorWidgetView, context: Context) {
        view.config = config
        view.history = history
        view.sample = sample
    }
}

private struct ShortcutField: NSViewRepresentable {
    let key: String
    let onChange: (Shortcut?) -> Void

    func makeNSView(context: Context) -> HotKeyField { HotKeyField(key: key, onChange: onChange) }
    func updateNSView(_ view: HotKeyField, context: Context) {}
}
