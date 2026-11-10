import Foundation

/// Nexo is a personal build with every former Pro capability enabled. This shim keeps AltTab call
/// sites compiling until sub-plan 3/14 removes the gates; it is deleted there.
enum ProFeature: Equatable, Hashable {
    case appIconsAndTitlesStyle
    case autoSize
    case searchOnReleaseShortcut
    case extraShortcut(index: Int)
    case searchInSwitcher

    func attemptUse() -> Bool { true }

    static func isStoredValuePro(preferenceKey: String) -> Bool { false }
}
