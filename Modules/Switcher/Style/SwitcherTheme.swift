import Cocoa

/// Nexo's customisable switcher look. Every field is optional: nil keeps what AltTab's `Appearance`
/// computes for the current style/size/theme, so an empty theme is exactly the stock look.
struct SwitcherTheme: Codable, Equatable {
    enum Material: String, Codable, CaseIterable {
        case dark, light, ultraDark, hud, sidebar, menu

        var title: String {
            switch self {
            case .dark: return NSLocalizedString("Dark", comment: "")
            case .light: return NSLocalizedString("Light", comment: "")
            case .ultraDark: return NSLocalizedString("Ultra dark", comment: "")
            case .hud: return NSLocalizedString("HUD", comment: "")
            case .sidebar: return NSLocalizedString("Sidebar", comment: "")
            case .menu: return NSLocalizedString("Menu", comment: "")
            }
        }

        var effectMaterial: NSVisualEffectView.Material {
            switch self {
            case .dark: return LegacyMaterial.dark
            case .light: return LegacyMaterial.mediumLight
            case .ultraDark: return LegacyMaterial.ultraDark
            case .hud: return .hudWindow
            case .sidebar: return .sidebar
            case .menu: return .menu
            }
        }
    }

    enum Animation: String, Codable, CaseIterable {
        case none, fade, quickFade, slowFade

        var title: String {
            switch self {
            case .none: return NSLocalizedString("None", comment: "")
            case .fade: return NSLocalizedString("Fade", comment: "")
            case .quickFade: return NSLocalizedString("Quick fade", comment: "")
            case .slowFade: return NSLocalizedString("Slow fade", comment: "")
            }
        }

        var duration: TimeInterval {
            switch self {
            case .none: return 0
            case .fade: return 0.2
            case .quickFade: return 0.1
            case .slowFade: return 0.35
            }
        }
    }

    // Colors as "#RRGGBBAA".
    var tintColor: String?
    var textColor: String?
    var highlightColor: String?
    var borderColor: String?
    var material: Material?
    var panelCornerRadius: CGFloat?
    var tileCornerRadius: CGFloat?
    var panelPadding: CGFloat?
    var borderWidth: CGFloat?
    var highlightBorderWidth: CGFloat?
    var iconScale: CGFloat?
    var fontSize: CGFloat?
    var showAnimation: Animation?
    var hideAnimation: Animation?

    static let stock = SwitcherTheme()

    static let compact = SwitcherTheme(panelCornerRadius: 10, tileCornerRadius: 6, panelPadding: 8,
        highlightBorderWidth: 2, iconScale: 0.8, fontSize: 11, showAnimation: SwitcherTheme.Animation.none, hideAnimation: .quickFade)

    static let glass = SwitcherTheme(tintColor: "#FFFFFF14", textColor: "#FFFFFFF2", highlightColor: "#FFFFFF40",
        borderColor: "#FFFFFF33", material: .hud, panelCornerRadius: 26, tileCornerRadius: 14, borderWidth: 1,
        highlightBorderWidth: 1.5, showAnimation: .fade, hideAnimation: .fade)
}

extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA".
    convenience init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let a = hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000FF" }
        let c = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", c[0], c[1], c[2], c[3])
    }
}
