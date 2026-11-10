import Foundation

enum Metric: String, CaseIterable {
    case cpu, gpu, memory, network, disk, battery, temperature

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .disk: return "Disk"
        case .battery: return "Battery"
        case .temperature: return "Temperature"
        }
    }

    var shortLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .network: return "NET"
        case .disk: return "SSD"
        case .battery: return "BAT"
        case .temperature: return "TMP"
        }
    }
}

/// One reading of every metric. Optional fields are nil when the source is unavailable or has no
/// delta yet (first CPU / network / disk sample).
struct MonitorSample {
    var cpu: Double? { cpuLoad?.total }
    var cpuLoad: CPULoad?
    var gpu: GPUStatus?
    var pressure = MemoryPressure(level: .normal, percent: nil)
    var memory: MemoryUsage?
    var network: (download: Double, upload: Double)?
    var diskIO: (read: Double, write: Double)?
    var diskFree: (free: Int64, total: Int64)?
    var battery: BatteryStatus?
    var temperature: (average: Double, maximum: Double)?
    var localAddress: (interface: String, address: String)?

    /// 0–1 value used for bars and history, per metric.
    func fraction(_ metric: Metric) -> Double? {
        switch metric {
        case .cpu: return cpu
        case .gpu: return gpu?.device
        case .memory: return pressure.percent.map { Double($0) / 100 }
        case .network: return network.map { min(1, ($0.download + $0.upload) / 12_500_000) } // relative to 100 Mbit/s
        case .disk: return diskFree.map { 1 - Double($0.free) / Double(max(1, $0.total)) }
        case .battery: return battery.map { Double($0.percent) / 100 }
        case .temperature: return temperature.map { min(1, $0.maximum / 100) }
        }
    }
}

/// Polls the readers on a timer and reacts immediately to kernel memory-pressure transitions.
final class MonitorSampler {
    static let historyLength = 60
    private let cpuReader = CPUReader()
    private let networkReader = NetworkReader()
    private let diskReader = DiskReader()
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private(set) var latest = MonitorSample()
    private(set) var history = [Metric: [Double]]()
    /// Raw network rates (bytes/s), oldest first, for the popover's upload/download chart.
    private(set) var networkHistory = [(download: Double, upload: Double)]()
    var enabledMetrics = Set(Metric.allCases)
    var onSample: ((MonitorSample) -> Void)?

    func start(interval: TimeInterval) {
        stop()
        sample()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        pressureSource = source
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    private func sample() {
        var sample = MonitorSample()
        sample.pressure = MemoryPressure.read()
        if enabledMetrics.contains(.cpu) { sample.cpuLoad = cpuReader.read() ?? latest.cpuLoad }
        if enabledMetrics.contains(.gpu) { sample.gpu = GPUReader.read() }
        if enabledMetrics.contains(.memory) { sample.memory = MemoryUsage.read() }
        if enabledMetrics.contains(.network) {
            sample.network = networkReader.read() ?? latest.network
            sample.localAddress = NetworkReader.localAddress()
        }
        if enabledMetrics.contains(.disk) {
            sample.diskIO = diskReader.throughput() ?? latest.diskIO
            sample.diskFree = DiskReader.freeSpace()
        }
        if enabledMetrics.contains(.battery) { sample.battery = BatteryReader.read() }
        if enabledMetrics.contains(.temperature) { sample.temperature = TemperatureReader.read() }
        latest = sample
        record(sample)
        onSample?(sample)
    }

    private func record(_ sample: MonitorSample) {
        for metric in Metric.allCases {
            guard let value = sample.fraction(metric) else { continue }
            var values = history[metric] ?? []
            values.append(value)
            if values.count > Self.historyLength { values.removeFirst(values.count - Self.historyLength) }
            history[metric] = values
        }
        if let network = sample.network {
            networkHistory.append(network)
            if networkHistory.count > Self.historyLength { networkHistory.removeFirst(networkHistory.count - Self.historyLength) }
        }
    }
}

enum MonitorFormat {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = bytesPerSecond
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return value < 10 && unit > 0 ? String(format: "%.1f%@/s", value, units[unit]) : "\(Int(value))\(units[unit])/s"
    }

    /// "709 KB/s": the rate with a space before the unit, for the menu bar network widget.
    static func spacedRate(_ bytesPerSecond: Double) -> String {
        let text = rate(bytesPerSecond)
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        return text[..<index] + " " + text[index...]
    }

    /// "28.9 GB": one decimal, short enough for a value column.
    static func gigabytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        return gb >= 100 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
