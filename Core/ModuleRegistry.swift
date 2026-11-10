import Foundation

/// Owns every module and its enabled/disabled state, persisted in UserDefaults as `module.<id>.enabled`.
final class ModuleRegistry {
    static let shared = ModuleRegistry()
    static let didChangeNotification = Notification.Name("NexoModuleRegistryDidChange")

    private(set) var modules: [NexoModule] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func register(_ module: NexoModule) {
        guard !modules.contains(where: { $0.id == module.id }) else { return }
        modules.append(module)
    }

    func startEnabledModules() {
        for module in modules where isEnabled(module) {
            module.start()
        }
    }

    func stopAll() {
        for module in modules where module.isRunning {
            module.stop()
        }
    }

    func isEnabled(_ module: NexoModule) -> Bool {
        guard let stored = defaults.object(forKey: key(module)) as? Bool else { return module.enabledByDefault }
        return stored
    }

    func setEnabled(_ enabled: Bool, for module: NexoModule) {
        defaults.set(enabled, forKey: key(module))
        applyRunningState(enabled, module)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: module)
    }

    func module(withId id: String) -> NexoModule? {
        modules.first { $0.id == id }
    }

    var enabledModules: [NexoModule] {
        modules.filter { isEnabled($0) }
    }

    private func applyRunningState(_ enabled: Bool, _ module: NexoModule) {
        if enabled && !module.isRunning { module.start() }
        if !enabled && module.isRunning { module.stop() }
    }

    private func key(_ module: NexoModule) -> String {
        "module.\(module.id).enabled"
    }
}
