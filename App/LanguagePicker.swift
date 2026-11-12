import Cocoa

/// Language of Nexo's whole UI (including the window switcher), picked in Settings → General.
/// AppKit reads `AppleLanguages` at launch, so a change applies after a restart.
enum NexoLanguage: CaseIterable {
    case system, english, spanish

    var title: String {
        switch self {
        case .system: return L("System default")
        case .english: return "English"
        case .spanish: return "Español"
        }
    }

    /// The switcher's own preference, kept in sync so both read the same choice.
    var switcherPreference: LanguagePreference {
        switch self {
        case .system: return .systemDefault
        case .english: return .english
        case .spanish: return .spanish
        }
    }

    static var current: NexoLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        let code = (domain?["AppleLanguages"] as? [String])?.first
        switch code {
        case "en"?: return .english
        case "es"?: return .spanish
        default: return .system
        }
    }

    func apply() {
        Preferences.set("language", switcherPreference.indexAsString, false)
        switcherPreference.applyToAppleLanguages()
    }
}

/// "Language" row for the General pane: a pop-up that offers to restart Nexo after a change.
final class LanguagePicker: NSStackView {
    private let popUp = NSPopUpButton()

    init() {
        super.init(frame: .zero)
        NexoLanguage.allCases.forEach { popUp.addItem(withTitle: $0.title) }
        popUp.selectItem(at: NexoLanguage.allCases.firstIndex(of: .current) ?? 0)
        popUp.target = self
        popUp.action = #selector(changed)
        spacing = 8
        addArrangedSubview(NSTextField(labelWithString: L("Language")))
        addArrangedSubview(popUp)
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    @objc private func changed() {
        let language = NexoLanguage.allCases[popUp.indexOfSelectedItem]
        guard language != .current else { return }
        language.apply()
        let alert = NSAlert()
        alert.messageText = L("Restart Nexo to change the language?")
        alert.informativeText = L("The new language is used from the next launch.")
        alert.addButton(withTitle: L("Restart Now"))
        alert.addButton(withTitle: L("Later")).keyEquivalent = "\u{1b}"
        let handle = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { App.restart() }
        }
        guard let window else { return handle(alert.runModal()) }
        alert.beginSheetModal(for: window, completionHandler: handle)
    }
}
