import Cocoa

struct ListeningPort: Equatable, Hashable {
    let port: Int
    let pid: Int32
    let command: String
    let address: String
}

/// TCP ports in LISTEN state, via `lsof -F` (machine-readable fields, run with an argument array).
enum PortScanner {
    static func scan() -> [ListeningPort] {
        guard let result = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 10) else { return [] }
        return parse(result.output)
    }

    /// `p<pid>` starts a process, `c<command>` names it, each `n<address:port>` is one socket.
    /// The same port appears once per address family (IPv4/IPv6); it is listed once. Exposed for tests.
    static func parse(_ output: String) -> [ListeningPort] {
        var pid: Int32?
        var command = ""
        var seen = Set<String>()
        var ports = [ListeningPort]()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)
            case "c": command = value
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                guard seen.insert("\(pid):\(port)").inserted else { continue }
                ports.append(ListeningPort(port: port, pid: pid, command: command, address: String(value[..<colon])))
            default: continue
            }
        }
        return ports.sorted { $0.port < $1.port }
    }
}

/// List listening ports and stop the process behind one (dev servers, databases, stuck daemons).
final class PortsModule: NexoModule {
    static let id = "ports"
    let title = "Port Manager"
    let icon = "network"
    private(set) var isRunning = false
    private var ports = [ListeningPort]()
    private var scanning = false

    func start() {
        isRunning = true
        refresh()
    }

    func stop() {
        isRunning = false
    }

    func menuItems() -> [NSMenuItem] {
        refresh()
        let item = NSMenuItem(title: "Listening Ports (\(ports.count))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if ports.isEmpty {
            let empty = NSMenuItem(title: scanning ? "Scanning…" : "None", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for port in ports { submenu.addItem(portItem(port)) }
        item.submenu = submenu
        return [item]
    }

    func settingsView() -> NSView {
        SettingsForm.stack([
            SettingsForm.note("Lists TCP ports in LISTEN state from `lsof`. “Quit” sends SIGTERM; “Force Kill” sends SIGKILL after confirmation. Processes owned by other users (root daemons) can't be stopped from here."),
        ])
    }

    private func refresh() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = PortScanner.scan()
            DispatchQueue.main.async {
                self?.ports = found
                self?.scanning = false
            }
        }
    }

    private func portItem(_ port: ListeningPort) -> NSMenuItem {
        let item = NSMenuItem(title: "\(port.port) — \(port.command) (pid \(port.pid))", action: nil, keyEquivalent: "")
        item.toolTip = "Listening on \(port.address):\(port.port)"
        let actions = NSMenu()
        for (title, signal) in [("Quit (SIGTERM)", SIGTERM), ("Force Kill (SIGKILL)…", SIGKILL)] {
            let action = NSMenuItem(title: title, action: #selector(stopProcess(_:)), keyEquivalent: "")
            action.target = self
            action.representedObject = [Int(port.pid), Int(signal), port.port]
            actions.addItem(action)
        }
        let copy = NSMenuItem(title: "Copy http://localhost:\(port.port)", action: #selector(copyURL(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = port.port
        actions.addItem(.separator())
        actions.addItem(copy)
        item.submenu = actions
        return item
    }

    @objc private func stopProcess(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [Int], values.count == 3 else { return }
        let pid = Int32(values[0])
        let signal = Int32(values[1])
        if signal == SIGKILL, !confirmForceKill(pid: pid, port: values[2]) { return }
        if kill(pid, signal) != 0 {
            let alert = NSAlert()
            alert.messageText = "Couldn't stop process \(pid)"
            alert.informativeText = String(cString: strerror(errno))
            alert.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    private func confirmForceKill(pid: Int32, port: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Force kill process \(pid) on port \(port)?"
        alert.informativeText = "The process won't get a chance to save its state."
        alert.addButton(withTitle: "Force Kill").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? Int else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://localhost:\(port)", forType: .string)
    }
}
