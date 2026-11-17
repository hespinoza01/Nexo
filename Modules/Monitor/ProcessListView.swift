import Cocoa
import SwiftUI

/// State of the Processes tab. Owned by `MonitorModule`, so filter, search and order survive
/// closing the popover.
final class ProcessListModel: ObservableObject {
    @Published private(set) var entries = [ProcessEntry]()
    @Published private(set) var loaded = false
    @Published var query = ProcessQuery() { didSet { refreshVisible() } }
    /// Filtered and sorted once per refresh or query change, not on every render.
    @Published private(set) var visible = [ProcessEntry]()
    @Published private(set) var unresponsiveCount = 0
    /// Row showing its Quit / Force Quit confirmation.
    @Published var confirming: pid_t?
    @Published private(set) var stopping = Set<pid_t>()
    @Published var message: String?
    private var icons = [pid_t: NSImage]()
    /// Asks the module for a fresh read right after a process was stopped.
    var onChange: (() -> Void)?

    /// A process that ignored Quit gets its button back after this long, so Force Quit is reachable.
    static let stoppingTimeout: TimeInterval = 8

    func publish(_ entries: [ProcessEntry]) {
        let alive = Set(entries.map(\.pid))
        icons = icons.filter { alive.contains($0.key) }
        stopping.formIntersection(alive)
        if let confirming, !alive.contains(confirming) { self.confirming = nil }
        self.entries = entries
        unresponsiveCount = entries.filter(\.isUnresponsive).count
        refreshVisible()
        loaded = true
    }

    /// Confirmations and messages belong to one opening of the popover.
    func resetTransient() {
        confirming = nil
        message = nil
    }

    private func refreshVisible() {
        visible = query.apply(entries)
    }

    func icon(_ entry: ProcessEntry) -> NSImage? {
        guard entry.bundleID != nil else { return nil }
        if let icon = icons[entry.pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: entry.pid)?.icon
        icons[entry.pid] = icon
        return icon
    }

    func toggleSort(_ sort: ProcessSort) {
        if query.sort == sort { query.ascending.toggle() } else {
            query.sort = sort
            query.ascending = sort == .name
        }
    }

    func terminate(_ entry: ProcessEntry, mode: TerminationMode) {
        confirming = nil
        stopping.insert(entry.pid)
        ProcessTerminator.terminate(entry, mode: mode) { [weak self] result in
            guard let self else { return }
            switch result {
            case .sent, .cancelled: self.message = nil
            case .gone: self.message = L("%@ already exited.", entry.name)
            case .failed(let reason): self.message = L("Couldn't stop %@: %@", entry.name, reason)
            }
            if result != .sent { self.stopping.remove(entry.pid) } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.stoppingTimeout) { self.stopping.remove(entry.pid) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.onChange?() }
        }
    }
}

struct ProcessListView: View {
    @ObservedObject var model: ProcessListModel
    private static let memoryWidth: CGFloat = 62
    private static let diskWidth: CGFloat = 62
    private static let cpuWidth: CGFloat = 44
    private static let actionWidth: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if let message = model.message { banner(message) }
            header
            Divider()
            list
            footer
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                SwiftUI.TextField(L("Search name or PID"), text: $model.query.search).textFieldStyle(.plain)
                if !model.query.search.isEmpty {
                    SwiftUI.Button { model.query.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
            Picker("", selection: $model.query.filter) {
                ForEach(ProcessFilter.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            sortButton(.name, L("Name")).frame(maxWidth: .infinity, alignment: .leading)
            sortButton(.memory, L("Memory")).frame(width: Self.memoryWidth, alignment: .trailing)
            sortButton(.disk, L("Disk")).frame(width: Self.diskWidth, alignment: .trailing)
            sortButton(.cpu, "CPU").frame(width: Self.cpuWidth, alignment: .trailing)
            Color.clear.frame(width: Self.actionWidth, height: 1)
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func sortButton(_ sort: ProcessSort, _ title: String) -> some View {
        SwiftUI.Button { model.toggleSort(sort) } label: {
            HStack(spacing: 2) {
                Text(title)
                if model.query.sort == sort { Image(systemName: model.query.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .foregroundStyle(model.query.sort == sort ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var list: some View {
        let rows = model.visible
        if !model.loaded {
            centered(L("Loading…"))
        } else if rows.isEmpty {
            centered(L("No matching processes"))
        } else {
            SwiftUI.ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { entry in
                        row(entry)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func row(_ entry: ProcessEntry) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                icon(entry)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                if entry.isUnresponsive {
                    Text(L("Not Responding"))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.18)))
                        .foregroundStyle(.red)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(L("PID %d · %@", entry.pid, Self.title(entry.kind)))
            if model.confirming == entry.pid {
                confirmation(entry)
            } else {
                Text(entry.memory.map(MonitorFormat.bytes) ?? "–").frame(width: Self.memoryWidth, alignment: .trailing)
                Text(entry.diskRate.map(MonitorFormat.rate) ?? "–").frame(width: Self.diskWidth, alignment: .trailing)
                Text(String(format: "%.1f", entry.cpu)).frame(width: Self.cpuWidth, alignment: .trailing)
                action(entry).frame(width: Self.actionWidth)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.vertical, 3)
        .background(entry.isUnresponsive ? Color.red.opacity(0.06) : Color.clear)
    }

    @ViewBuilder private func icon(_ entry: ProcessEntry) -> some View {
        if let image = model.icon(entry) {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: entry.kind == .system ? "gearshape.2" : "terminal")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private func action(_ entry: ProcessEntry) -> some View {
        if model.stopping.contains(entry.pid) {
            ProgressView().controlSize(.mini)
        } else if ProcessTerminator.canTerminate(entry) {
            SwiftUI.Button { model.confirming = entry.pid } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(entry.isUnresponsive ? Color.red : Color.secondary)
                .help(entry.kind == .system ? L("Stop (asks for an administrator password)") : L("Stop"))
        } else {
            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary).help(L("Protected system process"))
        }
    }

    /// Hung apps don't answer Quit, so Force Quit is the prominent choice for them.
    private func confirmation(_ entry: ProcessEntry) -> some View {
        HStack(spacing: 4) {
            SwiftUI.Button(L("Quit")) { model.terminate(entry, mode: .quit) }
                .buttonStyle(.bordered)
            SwiftUI.Button(L("Force Quit")) { model.terminate(entry, mode: .force) }
                .buttonStyle(.borderedProminent).tint(entry.isUnresponsive ? .red : .orange)
            SwiftUI.Button { model.confirming = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Cancel"))
        }
        .controlSize(.small)
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            SwiftUI.Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    private var footer: some View {
        let hung = model.unresponsiveCount
        return HStack {
            Text(L("%d processes", model.visible.count))
            Spacer()
            if hung > 0 { Text(L("%d not responding", hung)).foregroundStyle(.red) }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func centered(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func title(_ filter: ProcessFilter) -> String {
        switch filter {
        case .all: return L("All")
        case .apps: return L("Apps")
        case .background: return L("Background")
        case .system: return L("System")
        }
    }

    static func title(_ kind: ProcessKind) -> String {
        switch kind {
        case .app: return L("App")
        case .background: return L("Background")
        case .system: return L("System")
        }
    }
}
