import Foundation

/// Localized UI text. Keys are the English strings; translations live in `Localizable.strings`
/// (`Resources/l10n/<lang>.lproj`). The language is picked in Settings → General.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string, e.g. `L("%@ left", time)`. Use `%@` for strings and `%d` for Int.
func L(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(format, comment: ""), arguments: arguments)
}
