import Cocoa
import Security

/// Everything that helps tell what a process is and where it comes from. Read on demand, off the
/// main thread, when its detail page opens. Fields the kernel denies (other users' arguments) stay nil.
struct ProcessDetails: Equatable {
    struct Related: Equatable {
        let pid: pid_t
        var name: String
    }

    struct Bundle: Equatable {
        let path: String
        let name: String
        let identifier: String?
        let version: String?
    }

    struct Signature: Equatable {
        let identifier: String?
        let team: String?
        let authority: String?
    }

    var path: String?
    var arguments: [String]?
    var parent: Related?
    var responsible: Related?
    var user: String?
    var bundle: Bundle?
    var signature: Signature?
    var started: Date?
}

enum ProcessDetailsReader {
    private static let queue = DispatchQueue(label: "com.luckylopolis.nexo.monitor.processdetails", qos: .userInitiated)

    /// `completion` runs on main, where app names replace kernel names for parent and owner.
    static func read(_ entry: ProcessEntry, completion: @escaping (ProcessDetails) -> Void) {
        queue.async {
            var details = collect(entry)
            DispatchQueue.main.async {
                for keyPath in [\ProcessDetails.parent, \ProcessDetails.responsible] {
                    guard let related = details[keyPath: keyPath], let app = NSRunningApplication(processIdentifier: related.pid)?.localizedName else { continue }
                    details[keyPath: keyPath]?.name = app
                }
                completion(details)
            }
        }
    }

    private static func collect(_ entry: ProcessEntry) -> ProcessDetails {
        let pid = entry.pid
        let path = ProcessListReader.executablePath(pid)
        var details = ProcessDetails(path: path, arguments: arguments(pid), user: userName(entry.uid))
        if let parent = ProcessIdentity.parent(pid), parent.pid > 0 {
            details.parent = .init(pid: parent.pid, name: name(parent.pid, fallback: parent.command))
        }
        if let owner = ProcessIdentity.responsiblePID(pid), owner != pid {
            details.responsible = .init(pid: owner, name: name(owner, fallback: "pid \(owner)"))
        }
        details.bundle = path.flatMap(bundle)
        details.signature = signature(pid)
        details.started = entry.startTime.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
        return details
    }

    private static func name(_ pid: pid_t, fallback: String) -> String {
        let command = ProcessIdentity.parent(pid)?.command ?? fallback
        return ProcessListReader.displayName(command: command, path: ProcessListReader.executablePath(pid))
    }

    private static func userName(_ uid: uid_t) -> String? {
        guard let entry = getpwuid(uid) else { return "uid \(uid)" }
        return "\(String(cString: entry.pointee.pw_name)) (\(uid))"
    }

    /// `KERN_PROCARGS2`: argc, then the executable path, padding, argv and the environment, all
    /// NUL-separated. Only argv is kept; the environment may hold secrets. Exposed for tests.
    /// Walks by offsets: empty arguments are kept, and reading stops after exactly `argc` strings so
    /// an empty argument can never shift the environment into view. After the executable path the
    /// kernel pads with NULs up to the next 8-byte boundary of the string area (offset 4); measured on
    /// macOS 27.2, including a process exec'd with an empty argv[0], which then sits on that boundary.
    static func parseArguments(_ data: [UInt8]) -> [String]? {
        guard data.count > 4 else { return nil }
        let argc = Int(data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0 else { return nil }
        var index = 4
        while index < data.count, data[index] != 0 { index += 1 } // executable path
        index += 1
        while (index - 4) % 8 != 0 { // padding
            guard index < data.count, data[index] == 0 else { return nil }
            index += 1
        }
        var arguments = [String]()
        while arguments.count < argc {
            guard index < data.count, let end = data[index...].firstIndex(of: 0) else { return nil }
            arguments.append(String(decoding: data[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }

    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return nil }
        return parseArguments(Array(data.prefix(size)))
    }

    /// The outermost `.app` in the path: a helper deep inside Chrome.app is identified by Chrome.
    /// Exposed for tests.
    static func bundlePath(forExecutable path: String) -> String? {
        var components = [String]()
        for component in (path as NSString).pathComponents {
            components.append(component)
            if component.hasSuffix(".app") { return NSString.path(withComponents: components) }
        }
        return nil
    }

    private static func bundle(_ executable: String) -> ProcessDetails.Bundle? {
        guard let path = bundlePath(forExecutable: executable), let bundle = Foundation.Bundle(path: path) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? (path as NSString).lastPathComponent
        return .init(path: path, name: name, identifier: bundle.bundleIdentifier, version: info["CFBundleShortVersionString"] as? String)
    }

    private static func signature(_ pid: pid_t) -> ProcessDetails.Signature? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        let certificate = (values[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let signature = ProcessDetails.Signature(identifier: values[kSecCodeInfoIdentifier as String] as? String,
                                                 team: values[kSecCodeInfoTeamIdentifier as String] as? String,
                                                 authority: certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? })
        return signature.identifier == nil && signature.authority == nil ? nil : signature
    }
}
