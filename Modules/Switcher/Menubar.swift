import Cocoa

/// Switcher entries for Nexo's shared status menu. Adapted from AltTab's `Menubar` (GPL-3.0): Nexo owns
/// the only status item (`NexoCore.nsStatusItem`), so this no longer creates one, and the
/// Pro/update/feedback entries are gone.
enum Menubar {
    static var statusItem: NSStatusItem? { NexoCore.nsStatusItem }
    private static let permissionCallout = PermissionCallout()

    /// Kept as the launch hook AltTab calls once permissions are granted; nothing to build up-front
    /// since items are produced on each menu open.
    static func initialize() {}

    /// The switcher's own menubar-icon preferences don't apply to Nexo's shared icon.
    static func menubarIconCallback(_: NSControl?) {}

    /// The menu is rebuilt on every open, so the callout is re-evaluated there instead.
    static func refreshPermissionCallout() {}

    static func moduleMenuItems() -> [NSMenuItem] {
        var items = calloutItems()
        items.append(item(NSLocalizedString("Show", comment: "Menubar option"), #selector(App.showUiFromShortcut0), "eye"))
        items.append(item(NSLocalizedString("Switcher Settings…", comment: "Menubar option"), #selector(App.showSettingsWindow), "gear"))
        items.append(item(NSLocalizedString("Check permissions…", comment: "Menubar option"), #selector(App.checkPermissions), "hand.raised"))
        return items
    }

    // The callout is only useful when the user lacks Screen Recording AND has settings that need it
    // (Thumbnails style or window previews). Users who skipped the permission but use neither aren't
    // nagged (see AltTab #5623). Decision logic lives in `PermissionCalloutResolver`.
    private static func calloutItems() -> [NSMenuItem] {
        let dependentFeatures = Preferences.screenRecordingDependentFeatures
        let show = PermissionCalloutResolver.shouldShowCallout(
            screenRecordingGranted: ScreenRecordingPermission.status == .granted,
            dependentFeatures: dependentFeatures)
        guard show else { return [] }
        permissionCallout.update(dependentFeatures)
        let calloutItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        calloutItem.view = permissionCallout
        return [calloutItem, .separator()]
    }

    private static func item(_ title: String, _ action: Selector, _ symbolName: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = App.self
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        return item
    }
}

class PermissionCallout: StackView {
    private var label: NSTextField!
    private var button: NSButton!

    convenience init() {
        let label = NSTextField(wrappingLabelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.preferredMaxLayoutWidth = 250
        label.isSelectable = false
        label.addOrUpdateConstraint(label.widthAnchor, 250)
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.attributedTitle = NSAttributedString(string: NSLocalizedString("Grant permission", comment: "Menubar callout button"), attributes: [NSAttributedString.Key.foregroundColor: NSColor.white])
        self.init([label, button], .vertical, true, top: 8, right: 15, bottom: 10, left: 15)
        self.label = label
        self.button = button
        wantsLayer = true
        layer!.backgroundColor = NSColor.purple.cgColor
    }

    // NSControl target/action never fires inside an NSMenuItem custom view: the menu's modal
    // tracking loop swallows the click before the button's own mouse-tracking can call sendAction.
    // So we route the click through the container exactly like `UpgradeMenuItemView` — `hitTest`
    // keeps the button visual-only, and `mouseUp` runs the action and dismisses the menu. (#5771)
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard button.frame.contains(location) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        PermissionsWindow.grantScreenRecording()
    }

    // Name only the feature(s) the user actually enabled, so we never promise back a feature they
    // don't use. The wrapped label's height depends on the message, so re-fit after setting it.
    func update(_ dependentFeatures: PermissionCalloutResolver.DependentFeatures) {
        label.stringValue = PermissionCallout.message(dependentFeatures)
        // The earlier fit() pinned our height with a required constraint sized for the previous
        // (initially empty) message. While it stays active, fittingSize keeps reporting that stale
        // height, so re-fitting can't grow to fit the new text and the last line clips. Drop the
        // self-imposed size constraints first so fit() measures the real content. (#5771)
        constraints.filter {
            ($0.firstAnchor == widthAnchor || $0.firstAnchor == heightAnchor) && $0.secondAnchor == nil
        }.forEach { $0.isActive = false }
        fit()
    }

    // One reusable sentence template + a feature subject inserted at `%@`, so translators localize the
    // shared sentence (and the spacing/punctuation between its two clauses) once and only the subject
    // varies. The Thumbnails subject reuses the existing appearance-style string, already translated
    // everywhere. `.none` is unreachable here — the callout is hidden when no feature needs it.
    static func message(_ dependentFeatures: PermissionCalloutResolver.DependentFeatures) -> String {
        let subject: String
        switch dependentFeatures {
            case .thumbnails: subject = NSLocalizedString("Thumbnails", comment: "")
            case .previews: subject = NSLocalizedString("Window previews", comment: "Menubar callout subject: the preview-selected-window feature")
            case .both: subject = NSLocalizedString("Thumbnails and window previews", comment: "Menubar callout subject")
            case .none: return ""
        }
        return String(format: NSLocalizedString("Nexo is running without Screen Recording permissions. %@ won’t show.", comment: "Menubar callout. %@ is one or more feature names, e.g. Thumbnails"), subject)
    }
}
