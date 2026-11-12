import Cocoa

struct ListeningPort: Equatable, Hashable {
    let port: Int
    let pid: Int32
    let command: String
    let address: String
}

/// TCP ports in LISTEN state, via `lsof -F` (machine-readable fields, run with an argument array).
enum PortScanner {
    /// Re-reads one process right before signalling it: the menu may show a scan from minutes ago and
    /// the pid could now belong to something else.
    static func stillListening(_ port: ListeningPort) -> Bool {
        guard let result = Shell.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(port.pid), "-iTCP:\(port.port)", "-sTCP:LISTEN", "-F", "pcn"], timeout: 5) else { return false }
        return parse(result.output).contains { $0.pid == port.pid && $0.port == port.port && $0.command == port.command }
    }

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
    var title: String { L("Port Manager") }
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
        let item = NSMenuItem(title: L("Listening Ports (%d)", ports.count), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if ports.isEmpty {
            let empty = NSMenuItem(title: scanning ? L("Scanning…") : L("None"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for port in ports { submenu.addItem(portItem(port)) }
        item.submenu = submenu
        return [item]
    }

    func settingsView() -> NSView {
        SettingsForm.stack([
            SettingsForm.note(L("Lists TCP ports in LISTEN state from `lsof`. “Quit” sends SIGTERM; “Force Kill” sends SIGKILL after confirmation. Processes owned by other users (root daemons) can't be stopped from here.")),
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
        item.toolTip = L("Listening on %@:%d", port.address, port.port)
        let actions = NSMenu()
        for (title, signal) in [(L("Quit (SIGTERM)"), SIGTERM), (L("Force Kill (SIGKILL)…"), SIGKILL)] {
            let action = NSMenuItem(title: title, action: #selector(stopProcess(_:)), keyEquivalent: "")
            action.target = self
            action.representedObject = ["port": port, "signal": signal] as [String: Any]
            actions.addItem(action)
        }
        let copy = NSMenuItem(title: L("Copy http://localhost:%d", port.port), action: #selector(copyURL(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = port.port
        actions.addItem(.separator())
        actions.addItem(copy)
        item.submenu = actions
        return item
    }

    @objc private func stopProcess(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: Any], let port = values["port"] as? ListeningPort,
              let signal = values["signal"] as? Int32, port.pid > 1 else { return }
        if signal == SIGKILL, !confirmForceKill(port) { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard PortScanner.stillListening(port) else {
                DispatchQueue.main.async {
                    self?.showError(L("Port %d is no longer held by %@ (pid %d). Nothing was stopped.", port.port, port.command, port.pid))
                    self?.refresh()
                }
                return
            }
            let result = kill(port.pid, signal)
            let error = errno
            DispatchQueue.main.async {
                if result != 0 { self?.showError(L("Couldn't stop %@ (pid %d): %@", port.command, port.pid, String(cString: strerror(error)))) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refresh() }
            }
        }
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        NSApp.activate()
        alert.runModal()
    }

    private func confirmForceKill(_ port: ListeningPort) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Force kill %@ (pid %d) on port %d?", port.command, port.pid, port.port)
        alert.informativeText = L("The process won't get a chance to save its state.")
        alert.addButton(withTitle: L("Force Kill")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? Int else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://localhost:\(port)", forType: .string)
    }
}
