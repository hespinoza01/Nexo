import Cocoa

/// The active switcher theme plus named presets. Factory presets are built in and read-only; user
/// presets are JSON files in ~/Library/Application Support/Nexo/themes.
final class ThemeStore {
    static let shared = ThemeStore()
    static let didChangeNotification = Notification.Name("NexoSwitcherThemeDidChange")
    static let factoryPresets: [(name: String, theme: SwitcherTheme)] = [
        ("Default", .stock), ("Compact", .compact), ("Glass", .glass),
    ]

    private static let activeKey = "switcherTheme.active"
    private static let activeNameKey = "switcherTheme.activeName"
    private let directory: URL
    private let defaults: UserDefaults

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nexo/themes", isDirectory: true)
        self.defaults = defaults
    }

    var active: SwitcherTheme {
        guard let data = defaults.data(forKey: Self.activeKey),
              let theme = try? JSONDecoder().decode(SwitcherTheme.self, from: data) else { return .stock }
        return theme
    }

    var activeName: String {
        defaults.string(forKey: Self.activeNameKey) ?? "Default"
    }

    func setActive(_ theme: SwitcherTheme, name: String? = nil) {
        defaults.set(try? JSONEncoder().encode(theme), forKey: Self.activeKey)
        if let name { defaults.set(name, forKey: Self.activeNameKey) }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func isFactory(_ name: String) -> Bool {
        Self.factoryPresets.contains { $0.name == name }
    }

    var userPresetNames: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    var allPresetNames: [String] {
        Self.factoryPresets.map(\.name) + userPresetNames.filter { !isFactory($0) }
    }

    func preset(named name: String) -> SwitcherTheme? {
        if let factory = Self.factoryPresets.first(where: { $0.name == name }) { return factory.theme }
        return try? load(url(for: name))
    }

    /// Saves under `name` (factory names are reserved). Returns false if the name is invalid.
    @discardableResult
    func save(_ theme: SwitcherTheme, as name: String) -> Bool {
        let name = Self.sanitize(name)
        guard !name.isEmpty, !isFactory(name) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(theme, to: url(for: name))
            return true
        } catch {
            return false
        }
    }

    func delete(_ name: String) {
        guard !isFactory(name) else { return }
        try? FileManager.default.removeItem(at: url(for: name))
    }

    @discardableResult
    func rename(_ name: String, to newName: String) -> Bool {
        guard !isFactory(name), let theme = preset(named: name), save(theme, as: newName) else { return false }
        delete(name)
        if activeName == name { defaults.set(Self.sanitize(newName), forKey: Self.activeNameKey) }
        return true
    }

    func load(_ url: URL) throws -> SwitcherTheme {
        try JSONDecoder().decode(SwitcherTheme.self, from: Data(contentsOf: url))
    }

    func write(_ theme: SwitcherTheme, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: url, options: .atomic)
    }

    /// File-name safe: no path separators or leading dots.
    static func sanitize(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    }

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(Self.sanitize(name)).appendingPathExtension("json")
    }
}
