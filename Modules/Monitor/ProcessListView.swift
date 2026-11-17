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
    /// Process whose detail page is open, as listed when it was opened.
    @Published private(set) var selected: ProcessEntry?
    @Published private(set) var details: ProcessDetails?
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

    /// Confirmations, messages and the detail page belong to one opening of the popover.
    func resetTransient() {
        confirming = nil
        message = nil
        closeDetails()
    }

    func open(_ entry: ProcessEntry) {
        confirming = nil
        selected = entry
        details = nil
        ProcessDetailsReader.read(entry) { [weak self] details in
            // Display only (stopping needs a start time), so a missing one still shows its details.
            guard let selected = self?.selected, selected.pid == entry.pid, selected.startTime == entry.startTime else { return }
            self?.details = details
        }
    }

    func closeDetails() {
        selected = nil
        details = nil
    }

    /// Latest reading of the selected process; nil once it exited (or its pid was reused).
    var selectedNow: ProcessEntry? {
        guard let selected else { return nil }
        return entries.first { Self.same($0, selected) }
    }

    /// Without a start time there is no identity: a reused pid must not pass for the same process.
    static func same(_ a: ProcessEntry, _ b: ProcessEntry) -> Bool {
        a.pid == b.pid && a.startTime != nil && a.startTime == b.startTime
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
        Group {
            if let selected = model.selected {
                ProcessDetailView(model: model)
                    // A new process gets a fresh page: no Quit / Force Quit left open from the previous one.
                    .id("\(selected.pid):\(selected.startTime ?? 0)")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    controls
                    if let message = model.message { banner(message) }
                    header
                    Divider()
                    list
                    footer
                }
            }
        }
        // The popover's width comes from the panel; content never pushes it wider.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            filterBar
        }
    }

    /// Not a segmented Picker: once a segment is picked, AppKit gives every segment the widest
    /// label's width ("Segundo plano"), 460 pt, and the whole list overflowed the 396 pt panel.
    private var filterBar: some View {
        HStack(spacing: 2) {
            ForEach(ProcessFilter.allCases, id: \.self) { filter in
                let selected = model.query.filter == filter
                SwiftUI.Button { model.query.filter = filter } label: {
                    Text(Self.title(filter))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color(nsColor: .controlColor) : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 0.5, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .primary : .secondary)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
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
                Text(entry.name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if let owner = entry.owner, owner != entry.name {
                    Text(owner).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
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
            .contentShape(Rectangle())
            .onTapGesture { model.open(entry) }
            .accessibilityAddTraits(.isButton)
            .help(L("PID %d · %@ — click for details", entry.pid, Self.title(entry.kind)))
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
        ProcessIcon(model: model, entry: entry, size: 16)
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

    private func confirmation(_ entry: ProcessEntry) -> some View {
        ProcessStopButtons(model: model, entry: entry, onCancel: { model.confirming = nil })
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

struct ProcessIcon: View {
    @ObservedObject var model: ProcessListModel
    let entry: ProcessEntry
    let size: CGFloat

    var body: some View {
        if let image = model.icon(entry) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: entry.kind == .system ? "gearshape.2" : "terminal")
                .font(.system(size: size * 0.62)).foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}

/// Quit / Force Quit. Hung apps don't answer Quit, so Force Quit is the prominent choice for them.
struct ProcessStopButtons: View {
    @ObservedObject var model: ProcessListModel
    let entry: ProcessEntry
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            SwiftUI.Button(L("Quit")) { model.terminate(entry, mode: .quit) }
                .buttonStyle(.bordered)
            SwiftUI.Button(L("Force Quit")) { model.terminate(entry, mode: .force) }
                .buttonStyle(.borderedProminent).tint(entry.isUnresponsive ? .red : .orange)
            if let onCancel {
                SwiftUI.Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Cancel"))
            }
        }
        .controlSize(.small)
        .fixedSize()
    }
}

/// Detail page of one process: what it is, where its executable lives, who started it and who
/// signed it. Usage figures follow the live list.
struct ProcessDetailView: View {
    @ObservedObject var model: ProcessListModel
    /// Same two-step stop as the list: one click shows Quit / Force Quit.
    @State private var confirmingStop = false

    var body: some View {
        if let listed = model.selected {
            let live = model.selectedNow
            let entry = live ?? listed
            detail(listed: listed, live: live, entry: entry)
        }
    }

    private func detail(listed: ProcessEntry, live: ProcessEntry?, entry: ProcessEntry) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                SwiftUI.Button { model.closeDetails() } label: {
                    Label(L("Processes"), systemImage: "chevron.left").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                header(entry, alive: live != nil)
                if let message = model.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                usage(entry, alive: live != nil)
                Divider()
                SwiftUI.ScrollView {
                    if let details = model.details {
                        info(entry, details).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }
                actions(entry, alive: live != nil)
            }
        }
    }

    private func header(_ entry: ProcessEntry, alive: Bool) -> some View {
        HStack(spacing: 8) {
            ProcessIcon(model: model, entry: entry, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(ProcessListView.title(entry.kind)).foregroundStyle(.secondary)
                    if !alive {
                        Text(L("Exited")).foregroundStyle(.secondary)
                    } else if entry.isUnresponsive {
                        Text(L("Not Responding")).foregroundStyle(.red)
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    private func usage(_ entry: ProcessEntry, alive: Bool) -> some View {
        HStack(spacing: 0) {
            stat(L("Memory"), alive ? entry.memory.map(MonitorFormat.bytes) : nil)
            stat(L("Disk"), alive ? entry.diskRate.map(MonitorFormat.rate) : nil)
            stat("CPU", alive ? String(format: "%.1f%%", entry.cpu) : nil)
        }
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(spacing: 1) {
            Text(value ?? "–").font(.system(size: 13, weight: .medium).monospacedDigit())
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func info(_ entry: ProcessEntry, _ details: ProcessDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(L("PID"), "\(entry.pid)")
            if let parent = details.parent { row(L("Parent process"), "\(parent.name) (\(parent.pid))") }
            if let owner = details.responsible { row(L("Belongs to"), "\(owner.name) (\(owner.pid))") }
            if let user = details.user { row(L("User"), user) }
            if let started = details.started {
                row(L("Started"), started.formatted(date: .abbreviated, time: .standard))
            }
            if let bundle = details.bundle {
                row(L("App"), [bundle.name, bundle.version].compactMap { $0 }.joined(separator: " "))
                if let identifier = bundle.identifier { row(L("Bundle ID"), identifier) }
            }
            row(L("Location"), details.path ?? L("Not available"), monospaced: true)
            if let arguments = details.arguments, !arguments.isEmpty {
                row(L("Command"), arguments.joined(separator: " "), monospaced: true)
            }
            if let signature = details.signature {
                if let authority = signature.authority { row(L("Signed by"), authority) }
                if let team = signature.team { row(L("Team ID"), team) }
                if let identifier = signature.identifier, identifier != details.bundle?.identifier { row(L("Identifier"), identifier) }
            } else {
                row(L("Signed by"), L("Unsigned or not readable"))
            }
        }
        .font(.system(size: 11))
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
            Text(value)
                .font(monospaced ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions(_ entry: ProcessEntry, alive: Bool) -> some View {
        HStack(spacing: 6) {
            if let path = model.details?.path {
                SwiftUI.Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.details?.bundle?.path ?? path)]) } label: {
                    Image(systemName: "folder")
                }
                .help(L("Show in Finder"))
                SwiftUI.Button { Self.copy(path) } label: { Image(systemName: "doc.on.doc") }
                    .help(L("Copy location"))
            }
            SwiftUI.Button { Self.copy("\(entry.pid)") } label: { Text("PID") }
                .help(L("Copy PID"))
            Spacer(minLength: 0)
            if alive {
                if model.stopping.contains(entry.pid) {
                    ProgressView().controlSize(.small)
                } else if ProcessTerminator.canTerminate(entry) {
                    if confirmingStop {
                        ProcessStopButtons(model: model, entry: entry, onCancel: { confirmingStop = false })
                    } else {
                        SwiftUI.Button(L("Stop")) { confirmingStop = true }
                    }
                } else {
                    Label(L("Protected system process"), systemImage: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
