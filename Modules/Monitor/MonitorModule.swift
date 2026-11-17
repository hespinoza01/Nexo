import Cocoa
import ShortcutRecorder
import Combine
import SwiftUI

/// System monitor in its own status item (Stats-like readouts), with a detail popover and history.
/// Memory is shown as the kernel's memory pressure, like Activity Monitor; occupancy is listed apart.
/// Everything visual is configurable through `MonitorAppearance` (see `MonitorSettingsView`).
final class MonitorModule: NexoModule {
    static let id = "monitor"
    let title = L("System Monitor")
    let icon = "gauge.with.dots.needle.33percent"
    private(set) var isRunning = false

    enum Key {
        static let interval = "monitor.interval"
        static let shortcut = "monitor.shortcut"
    }

    static let intervals: [TimeInterval] = [1, 2, 3, 5]
    let store = MonitorAppearanceStore()
    let live = MonitorLiveModel()
    private let sampler = MonitorSampler()
    private let alerter = MonitorAlerter()
    private var statusItem: NSStatusItem?
    private let widget = MonitorWidgetView()
    private let popover = NSPopover()
    private var detail: MonitorDetailViewController?
    private var observation: AnyCancellable?
    let processList = ProcessListModel()
    private let processReader = ProcessListReader()
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.togglePopover() }

    var interval: TimeInterval {
        get { Self.intervals.contains(UserDefaults.standard.double(forKey: Key.interval)) ? UserDefaults.standard.double(forKey: Key.interval) : 2 }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.interval)
            if isRunning { sampler.start(interval: newValue) }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installStatusItem()
        sampler.onSample = { [weak self] sample in self?.render(sample) }
        observation = store.$appearance.dropFirst().sink { [weak self] appearance in
            DispatchQueue.main.async { self?.refreshWidget(appearance) }
        }
        refreshWidget(store.appearance)
        sampler.start(interval: interval)
        hotKey.register(ShortcutStore.load(Key.shortcut))
        alerter.requestAuthorizationIfNeeded(store.appearance.alerts)
        processList.onChange = { [weak self] in self?.refreshProcessList() }
    }

    func stop() {
        isRunning = false
        sampler.stop()
        hotKey.unregister()
        observation = nil
        popover.close()
        detail = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func menuItems() -> [NSMenuItem] {
        let sample = sampler.latest
        var lines = [L("Memory pressure: %@ (%@)", sample.pressure.percent.map { "\($0)%" } ?? "–", Self.levelName(sample.pressure.level))]
        if let cpu = sample.cpu { lines.append("CPU: \(MonitorFormat.percent(cpu))") }
        return lines.map {
            let item = NSMenuItem(title: $0, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
    }

    func settingsView() -> NSView {
        live.seed(sampler.latest, history: sampler.history)
        let view = MonitorSettingsView(store: store, live: live, module: self)
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        return hosting
    }

    func registerShortcut(_ shortcut: Shortcut?) {
        guard isRunning else { return }
        hotKey.register(shortcut)
    }

    static func levelName(_ level: MemoryPressure.Level) -> String {
        switch level {
        case .normal: return L("normal")
        case .warning: return L("warning")
        case .critical: return L("critical")
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
        button.action = #selector(statusItemClicked)
        statusItem = item
    }

    private func refreshWidget(_ appearance: MonitorAppearance) {
        widget.config = appearance
        statusItem?.isVisible = !appearance.menuBarMetrics.isEmpty
        statusItem?.length = widget.intrinsicContentSize.width
        alerter.requestAuthorizationIfNeeded(appearance.alerts)
    }

    private func render(_ sample: MonitorSample) {
        widget.history = sampler.history
        widget.sample = sample
        statusItem?.length = widget.intrinsicContentSize.width
        alerter.evaluate(sample, store.appearance.alerts)
        live.publish(sample, history: sampler.history)
        guard popover.isShown, let detail else { return }
        detail.update(sample, history: sampler.history, networkHistory: sampler.networkHistory)
        refreshProcesses(detail)
    }

    /// Only the visible tab measures processes: the full list on Processes, the top few on Summary.
    private func refreshProcesses(_ detail: MonitorDetailViewController) {
        if detail.isShowingProcesses { return refreshProcessList() }
        TopProcessesReader.read(limit: processLimit) { [weak detail] in detail?.update(processes: $0) }
    }

    private func refreshProcessList() {
        guard popover.isShown, detail?.isShowingProcesses == true else { return }
        processReader.read { [weak self] in self?.processList.publish($0) }
    }

    /// No `ps` at all when neither section that lists processes is visible.
    private var processLimit: Int {
        let a = store.appearance
        return a.isSectionVisible(.cpu) || a.isSectionVisible(.memory) ? a.popover.topProcesses : 0
    }

    @objc private func statusItemClicked() {
        togglePopover()
    }

    private func togglePopover() {
        guard !popover.isShown else {
            popover.close()
            detail = nil
            return
        }
        // Hidden item (no metric enabled): the button has no window to anchor the popover to.
        guard statusItem?.isVisible == true, let button = statusItem?.button, button.window != nil else { return }
        processList.resetTransient()
        let controller = MonitorDetailViewController(config: store.appearance, processes: processList)
        detail = controller
        _ = controller.view
        controller.update(sampler.latest, history: sampler.history, networkHistory: sampler.networkHistory)
        controller.onTabChange = { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.refreshProcesses(controller)
        }
        popover.contentViewController = controller
        controller.popover = popover
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        refreshProcesses(controller)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Latest sample for the settings preview; published only while the preview is on screen.
final class MonitorLiveModel: ObservableObject {
    static var previewVisible = false
    @Published private(set) var sample = MonitorSample()
    @Published private(set) var history = [Metric: [Double]]()

    func publish(_ sample: MonitorSample, history: [Metric: [Double]]) {
        guard Self.previewVisible else { return }
        seed(sample, history: history)
    }

    func seed(_ sample: MonitorSample, history: [Metric: [Double]]) {
        self.sample = sample
        self.history = history
    }
}
