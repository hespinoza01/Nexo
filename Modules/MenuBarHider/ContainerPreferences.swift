import Foundation

/// Reads and writes MenuBarAgent's allow list (see `TrackedApplications`).
protocol AllowListStore: AnyObject {
    func read() throws -> [Any]
    func write(_ array: [Any]) throws
}

/// The real list in Control Center's group container.
///
/// Goes through CoreFoundation's private container-aware preference calls: a path-based write changes
/// the file but MenuBarAgent only notices after a restart, while these reach its observers and items
/// fade out in ~250 ms. Reading the container needs Full Disk Access; cfprefsd refuses otherwise
/// ("requires user-preference-read or file-read-data sandbox access", measured on 27.2).
final class ControlCenterAllowList: AllowListStore {
    enum Failure: Error { case unavailable, unreadable, notSynchronized }

    private typealias Copy = @convention(c) (CFString, CFString, CFString, CFString, CFString) -> Unmanaged<CFPropertyList>?
    private typealias SetValue = @convention(c) (CFString, CFPropertyList?, CFString, CFString, CFString, CFString) -> Void
    private typealias Synchronize = @convention(c) (CFString, CFString, CFString, CFString) -> Bool

    private struct Functions {
        let copy: Copy
        let set: SetValue
        let synchronize: Synchronize

        static let shared: Functions? = {
            guard let handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW),
                  let copy = dlsym(handle, "_CFPreferencesCopyValueWithContainer"),
                  let set = dlsym(handle, "_CFPreferencesSetValueWithContainer"),
                  let synchronize = dlsym(handle, "_CFPreferencesSynchronizeWithContainer") else { return nil }
            return Functions(copy: unsafeBitCast(copy, to: Copy.self), set: unsafeBitCast(set, to: SetValue.self),
                synchronize: unsafeBitCast(synchronize, to: Synchronize.self))
        }()
    }

    static let shared = ControlCenterAllowList()
    private static let key = "trackedApplications" as CFString
    private static let applicationID = "group.com.apple.controlcenter" as CFString
    private static var container: CFString { (NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter") as CFString }

    static var isSupported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && Functions.shared != nil }

    /// False until Nexo has Full Disk Access (or the list does not exist yet).
    var isReadable: Bool { (try? read()) != nil }

    func read() throws -> [Any] {
        guard let functions = Functions.shared else { throw Failure.unavailable }
        guard let value = functions.copy(Self.key, Self.applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, Self.container)?.takeRetainedValue(),
              let data = value as? Data, let array = TrackedApplications.decode(data) else { throw Failure.unreadable }
        return array
    }

    func write(_ array: [Any]) throws {
        guard let functions = Functions.shared else { throw Failure.unavailable }
        let data = try TrackedApplications.encode(array)
        functions.set(Self.key, data as CFData, Self.applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, Self.container)
        guard functions.synchronize(Self.applicationID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, Self.container) else { throw Failure.notSynchronized }
    }
}
