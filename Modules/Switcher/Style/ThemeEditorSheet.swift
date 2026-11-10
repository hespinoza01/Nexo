import Cocoa
import UniformTypeIdentifiers

/// Nexo style editor: presets (save / load / rename / delete / import / export) and every
/// `SwitcherTheme` property, with a live mock preview. Changes apply to the switcher immediately.
final class ThemeEditorSheet: SheetWindow {
    private let store = ThemeStore.shared
    private var theme = ThemeStore.shared.active
    private let preview = ThemePreviewView()
    private let presetPopUp = NSPopUpButton()
    private var controls = [NSView]()

    override func makeContentView() -> NSView {
        reloadPresets()
        presetPopUp.target = self
        presetPopUp.action = #selector(presetChosen(_:))
        let presetButtons = NSStackView(views: [
            button("Save As…", #selector(saveAs)), button("Rename…", #selector(renamePreset)), button("Delete", #selector(deletePreset)),
            button("Import…", #selector(importPreset)), button("Export…", #selector(exportPreset)),
        ])
        presetButtons.spacing = 6
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 140).isActive = true
        preview.widthAnchor.constraint(equalToConstant: SheetWindow.width).isActive = true
        let form = NSGridView(views: rows())
        form.columnSpacing = 10
        form.rowSpacing = 6
        form.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [SettingsForm.row("Preset", presetPopUp), presetButtons, preview, form])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        refreshPreview()
        return stack
    }

    // MARK: - Form

    private func rows() -> [[NSView]] {
        [
            ["Panel tint", colorRow(\.tintColor)],
            ["Text color", colorRow(\.textColor)],
            ["Selection color", colorRow(\.highlightColor)],
            ["Border color", colorRow(\.borderColor)],
            ["Material", materialPopUp()],
            ["Panel corner radius", slider(\.panelCornerRadius, 0...40)],
            ["Tile corner radius", slider(\.tileCornerRadius, 0...30)],
            ["Panel padding", slider(\.panelPadding, 0...40)],
            ["Border width", slider(\.borderWidth, 0...6)],
            ["Selection border", slider(\.highlightBorderWidth, 0...6)],
            ["Icon size ×", slider(\.iconScale, 0.5...1.5)],
            ["Font size", slider(\.fontSize, 9...20)],
            ["Show animation", animationPopUp(\.showAnimation)],
            ["Hide animation", animationPopUp(\.hideAnimation)],
        ].map { [NSTextField(labelWithString: $0[0] as! String), $0[1] as! NSView] }
    }

    /// Color well + "Default" checkbox: unchecked means the theme sets the color.
    private func colorRow(_ keyPath: WritableKeyPath<SwitcherTheme, String?>) -> NSView {
        let well = NSColorWell(style: .minimal)
        well.color = NSColor(hex: theme[keyPath: keyPath]) ?? .systemAccentColor
        let useDefault = NSButton(checkboxWithTitle: "Default", target: nil, action: nil)
        useDefault.state = theme[keyPath: keyPath] == nil ? .on : .off
        well.isEnabled = useDefault.state == .off
        let apply = { [weak self, weak well, weak useDefault] in
            guard let self, let well, let useDefault else { return }
            well.isEnabled = useDefault.state == .off
            self.update { $0[keyPath: keyPath] = useDefault.state == .on ? nil : well.color.hexString }
        }
        well.onAction = { _ in apply() }
        useDefault.onAction = { _ in apply() }
        return NSStackView(views: [well, useDefault])
    }

    private func slider(_ keyPath: WritableKeyPath<SwitcherTheme, CGFloat?>, _ range: ClosedRange<Double>) -> NSView {
        let slider = NSSlider(value: Double(theme[keyPath: keyPath] ?? CGFloat(range.lowerBound)), minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        slider.isContinuous = true
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        value.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let useDefault = NSButton(checkboxWithTitle: "Default", target: nil, action: nil)
        useDefault.state = theme[keyPath: keyPath] == nil ? .on : .off
        slider.isEnabled = useDefault.state == .off
        let format = { range.upperBound <= 2 ? String(format: "%.2f", slider.doubleValue) : "\(Int(slider.doubleValue))" }
        value.stringValue = useDefault.state == .on ? "–" : format()
        let apply = { [weak self, weak slider, weak value, weak useDefault] in
            guard let self, let slider, let value, let useDefault else { return }
            slider.isEnabled = useDefault.state == .off
            value.stringValue = useDefault.state == .on ? "–" : format()
            self.update { $0[keyPath: keyPath] = useDefault.state == .on ? nil : CGFloat(slider.doubleValue) }
        }
        slider.onAction = { _ in apply() }
        useDefault.onAction = { _ in apply() }
        return NSStackView(views: [slider, value, useDefault])
    }

    private func materialPopUp() -> NSView {
        let popUp = NSPopUpButton()
        popUp.addItem(withTitle: "Default")
        SwitcherTheme.Material.allCases.forEach { popUp.addItem(withTitle: $0.title) }
        popUp.selectItem(at: theme.material.flatMap { SwitcherTheme.Material.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        popUp.onAction = { [weak self] control in
            let index = (control as! NSPopUpButton).indexOfSelectedItem
            self?.update { $0.material = index == 0 ? nil : SwitcherTheme.Material.allCases[index - 1] }
        }
        return popUp
    }

    private func animationPopUp(_ keyPath: WritableKeyPath<SwitcherTheme, SwitcherTheme.Animation?>) -> NSView {
        let popUp = NSPopUpButton()
        popUp.addItem(withTitle: "Default")
        SwitcherTheme.Animation.allCases.forEach { popUp.addItem(withTitle: $0.title) }
        popUp.selectItem(at: theme[keyPath: keyPath].flatMap { SwitcherTheme.Animation.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        popUp.onAction = { [weak self] control in
            let index = (control as! NSPopUpButton).indexOfSelectedItem
            self?.update { $0[keyPath: keyPath] = index == 0 ? nil : SwitcherTheme.Animation.allCases[index - 1] }
        }
        return popUp
    }

    private func update(_ change: (inout SwitcherTheme) -> Void) {
        change(&theme)
        store.setActive(theme, name: "Custom")
        App.resetPreferencesDependentComponents()
        reloadPresets()
        refreshPreview()
    }

    private func refreshPreview() {
        preview.theme = theme
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    // MARK: - Presets

    private func reloadPresets() {
        presetPopUp.removeAllItems()
        var names = store.allPresetNames
        if !names.contains(store.activeName) { names.insert(store.activeName, at: 0) }
        presetPopUp.addItems(withTitles: names)
        presetPopUp.selectItem(withTitle: store.activeName)
    }

    /// Switching preset rebuilds the form so every control shows the preset's values.
    @objc private func presetChosen(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem, let preset = store.preset(named: name) else { return }
        theme = preset
        store.setActive(preset, name: name)
        App.resetPreferencesDependentComponents()
        rebuild()
    }

    @objc private func saveAs() {
        guard let name = ask("Save style as", defaultValue: store.isFactory(store.activeName) ? "" : store.activeName) else { return }
        guard store.save(theme, as: name) else { return alert("“\(name)” can't be used (built-in presets are read-only).") }
        store.setActive(theme, name: ThemeStore.sanitize(name))
        reloadPresets()
    }

    @objc private func renamePreset() {
        let current = store.activeName
        guard !store.isFactory(current), store.userPresetNames.contains(current) else { return alert("Only saved presets can be renamed.") }
        guard let name = ask("Rename “\(current)” to", defaultValue: current), store.rename(current, to: name) else { return }
        reloadPresets()
    }

    @objc private func deletePreset() {
        let current = store.activeName
        guard store.userPresetNames.contains(current) else { return alert("Built-in presets can't be deleted.") }
        store.delete(current)
        store.setActive(.stock, name: "Default")
        theme = .stock
        App.resetPreferencesDependentComponents()
        rebuild()
    }

    @objc private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try store.load(url)
            let name = url.deletingPathExtension().lastPathComponent
            store.save(imported, as: name)
            theme = imported
            store.setActive(imported, name: ThemeStore.sanitize(name))
            App.resetPreferencesDependentComponents()
            rebuild()
        } catch {
            alert("That file isn't a Nexo style: \(error.localizedDescription)")
        }
    }

    @objc private func exportPreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(store.activeName).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.write(theme, to: url) } catch { alert(error.localizedDescription) }
    }

    private func rebuild() {
        setupView()
    }

    private func ask(_ message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}

/// A mock switcher panel (three tiles, the middle one selected) drawn from a theme.
final class ThemePreviewView: NSView {
    var theme = SwitcherTheme.stock { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = theme.panelCornerRadius ?? 18
        let padding = theme.panelPadding ?? 14
        let panel = bounds.insetBy(dx: 40, dy: 8)
        let isLight = theme.material == .light
        (isLight ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
        NSBezierPath(roundedRect: panel, xRadius: radius, yRadius: radius).fill()
        if let tint = NSColor(hex: theme.tintColor) {
            tint.setFill()
            NSBezierPath(roundedRect: panel, xRadius: radius, yRadius: radius).fill()
        }
        if let border = NSColor(hex: theme.borderColor), let width = theme.borderWidth, width > 0 {
            border.setStroke()
            let path = NSBezierPath(roundedRect: panel.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
            path.lineWidth = width
            path.stroke()
        }
        let content = panel.insetBy(dx: padding, dy: padding)
        let tileWidth = (content.width - 2 * 10) / 3
        for index in 0..<3 {
            drawTile(NSRect(x: content.minX + CGFloat(index) * (tileWidth + 10), y: content.minY, width: tileWidth, height: content.height),
                selected: index == 1, isLight: isLight)
        }
    }

    private func drawTile(_ rect: NSRect, selected: Bool, isLight: Bool) {
        let radius = theme.tileCornerRadius ?? 10
        let accent = NSColor(hex: theme.highlightColor) ?? .controlAccentColor
        if selected {
            accent.withAlphaComponent(0.2 * accent.alphaComponent).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            accent.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            border.lineWidth = theme.highlightBorderWidth ?? 3
            border.stroke()
        }
        let icon = CGFloat(30) * (theme.iconScale ?? 1)
        NSColor.systemGray.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - icon / 2, y: rect.midY - icon / 2 + 8, width: icon, height: icon), xRadius: 7, yRadius: 7).fill()
        let textColor = NSColor(hex: theme.textColor) ?? (isLight ? NSColor.black.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.85))
        let font = NSFont.systemFont(ofSize: theme.fontSize ?? 12, weight: .medium)
        let title = "Window" as NSString
        let size = title.size(withAttributes: [.font: font])
        title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 6), withAttributes: [.font: font, .foregroundColor: textColor])
    }
}
