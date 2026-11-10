import Cocoa

/// Small AppKit layout helpers shared by module settings pages.
enum SettingsForm {
    static func stack(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func row(_ label: String, _ controls: NSView...) -> NSStackView {
        let stack = NSStackView(views: [NSTextField(labelWithString: label)] + controls)
        stack.spacing = 8
        return stack
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }
}
