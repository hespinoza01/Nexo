import Cocoa
import Darwin

enum TerminationMode: Equatable {
    /// Lets the process clean up: an app's Quit, SIGTERM otherwise.
    case quit
    /// Immediate: Force Quit for apps, SIGKILL otherwise.
    case force

    var signal: Int32 { self == .quit ? SIGTERM : SIGKILL }
    /// Argument for `/bin/kill -<name>`; fixed strings, never user input.
    var signalName: String { self == .quit ? "TERM" : "KILL" }
}

enum TerminationResult: Equatable {
    case sent
    /// The pid no longer belongs to the listed process (it exited or the pid was reused).
    case gone
    case cancelled
    case failed(String)
}

/// Stops the process behind a row of the Processes tab. Every path re-checks that the pid still
/// belongs to the same process right before acting, because the list may be seconds old.
enum ProcessTerminator {
    /// Killing any of these logs the user out, freezes the screen or panics the kernel.
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "opendirectoryd", "securityd", "configd",
        "coreservicesd", "diskarbitrationd", "fseventsd", "powerd", "logd", "notifyd", "mds", "syspolicyd",
        "trustd", "distnoted", "cfprefsd", "runningboardd", "UserEventAgent", "kextd", "kernelmanagerd",
    ]

    static func canTerminate(_ entry: ProcessEntry, ownPID: pid_t = getpid()) -> Bool {
        entry.pid > 1 && entry.pid != ownPID && entry.startTime != nil && !protectedNames.contains(entry.name)
    }

    /// Same process as when the list was read: same start time (microseconds) for that pid.
    static func isSameProcess(_ entry: ProcessEntry, currentStart: UInt64?) -> Bool {
        guard let listed = entry.startTime, let currentStart else { return false }
        return listed == currentStart
    }

    /// `completion` runs on main.
    static func terminate(_ entry: ProcessEntry, mode: TerminationMode, completion: @escaping (TerminationResult) -> Void) {
        guard canTerminate(entry) else { return completion(.failed(L("This process is protected."))) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(entry, mode)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func run(_ entry: ProcessEntry, _ mode: TerminationMode) -> TerminationResult {
        guard isSameProcess(entry, currentStart: ProcessIdentity.startTime(entry.pid)) else { return .gone }
        if entry.uid != getuid() {
            // Verify, capture, verify: the captured text must belong to the listed process.
            guard let started = startedText(entry.pid),
                  isSameProcess(entry, currentStart: ProcessIdentity.startTime(entry.pid)) else { return .gone }
            return runAsAdmin(entry.pid, mode, started: started)
        }
        dispatchPrecondition(condition: .notOnQueue(.main))
        if entry.kind == .app, let result = DispatchQueue.main.sync(execute: { quitApp(entry.pid, mode) }) { return result }
        guard kill(entry.pid, mode.signal) == 0 else {
            let error = errno
            return error == ESRCH ? .gone : .failed(String(cString: strerror(error)))
        }
        return .sent
    }

    /// Nil when the app is gone from NSWorkspace but the pid lives on; the caller falls back to a signal.
    private static func quitApp(_ pid: pid_t, _ mode: TerminationMode) -> TerminationResult? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let accepted = mode == .quit ? app.terminate() : app.forceTerminate()
        return accepted ? .sent : nil
    }

    /// `ps`' start time ("Tue Nov 17 06:47:46 2026"), read just after the identity check. The privileged
    /// script compares it again after the password prompt, which can take minutes, and only then signals.
    private static func startedText(_ pid: pid_t) -> String? {
        guard let output = Shell.run("/usr/bin/env", ["LC_ALL=C", "/bin/ps", "-o", "lstart=", "-p", String(pid)], timeout: 3)?.output else { return nil }
        return normalizedStart(output)
    }

    /// `ps` pads the column and the day ("Jan  1"); the script normalizes with `xargs` the same way.
    static func normalizedStart(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Other users' processes need root. macOS asks for an administrator password; pid, signal and
    /// start time travel as `argv` and are quoted inside the script, so nothing is interpolated.
    static func adminArguments(pid: pid_t, mode: TerminationMode, started: String) -> [String] {
        let script = [
            "on run argv",
            "set {signalName, pidText, started} to {item 1 of argv, quoted form of (item 2 of argv), quoted form of (item 3 of argv)}",
            "try",
            "return do shell script \"if [ \\\"$(LC_ALL=C /bin/ps -o lstart= -p \" & pidText & \" | /usr/bin/xargs)\\\" = \" & started & \" ]; then /bin/kill -\" & signalName & \" \" & pidText & \" && echo ok; else echo gone; fi\" with administrator privileges",
            "on error message number code",
            "if code is -128 then return \"cancelled\"",
            "return \"error:\" & message",
            "end try",
            "end run",
        ]
        return script.flatMap { ["-e", $0] } + [mode.signalName, String(pid), started]
    }

    static func adminResult(_ output: String?) -> TerminationResult {
        guard let output = output?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .failed(L("Couldn't ask for administrator rights.")) }
        switch output {
        case "ok": return .sent
        case "gone": return .gone
        case "cancelled": return .cancelled
        default:
            return output.hasPrefix("error:") ? .failed(String(output.dropFirst(6))) : .failed(L("Couldn't ask for administrator rights."))
        }
    }

    private static func runAsAdmin(_ pid: pid_t, _ mode: TerminationMode, started: String) -> TerminationResult {
        adminResult(Shell.run("/usr/bin/osascript", adminArguments(pid: pid, mode: mode, started: started), timeout: 300)?.output)
    }
}
