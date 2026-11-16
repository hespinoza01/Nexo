import SwiftUI

/// Sections of menu bar icons: what is shown, hidden until revealed, and always hidden; plus reordering.
struct MenuBarLayoutView: View {
    @ObservedObject var manager: MenuBarManager
    @State private var draggedItem: String?
    @State private var dropItem: String?
    @State private var dropSection: MenuBarSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !ControlCenterAllowList.isSupported {
                Text(L("Hiding other apps' icons needs macOS 27 or later.")).foregroundStyle(.secondary)
            } else if !manager.hasAccess {
                accessBanner
            } else if !manager.isActive {
                Text(L("Turn the module on to hide icons.")).foregroundStyle(.orange).font(.callout)
            }
            if let error = manager.lastError {
                Text(error).foregroundStyle(.orange).font(.callout)
            }
            revealControls
            visibleSection
            appSection(.hidden, title: L("Hidden"), note: L("Shown for a few seconds with the shortcut or from the Nexo menu."))
            appSection(.alwaysHidden, title: L("Always hidden"), note: L("Stay hidden until you move them to another section."))
            SystemItemsSection(manager: manager)
            HStack {
                SwiftUI.Button(L("Reload")) { manager.refresh() }
                SwiftUI.Button(L("Show all icons again")) { manager.showEverything() }.disabled(!manager.isActive)
                if manager.isScanning || manager.isMoving { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { manager.refresh() }
    }

    private var accessBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Nexo needs Full Disk Access"), systemImage: "lock.shield").font(.headline)
            Text(L("macOS keeps each app's “Allow in the Menu Bar” switch in a protected file. Add Nexo in Privacy & Security › Full Disk Access, then come back to this page."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SwiftUI.Button(L("Open Full Disk Access…")) { PermissionCenter.openSettings(.fullDiskAccess) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var revealControls: some View {
        HStack(spacing: 10) {
            SwiftUI.Button(manager.isRevealed ? L("Hide again") : L("Show hidden icons")) { manager.toggleReveal() }
                .disabled(!manager.isActive || (!manager.isRevealed && !manager.canReveal))
            Picker(L("Hide again after"), selection: Binding(get: { manager.revealSeconds }, set: { manager.revealSeconds = $0 })) {
                ForEach(MenuBarManager.revealChoices, id: \.self) { Text(L("%d s", $0)).tag($0) }
            }
            .fixedSize()
        }
    }

    private var visibleSection: some View {
        GroupBox(label: Text(L("Visible")).font(.headline)) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Left to right, as in the menu bar. Drag an icon to reorder it, or onto a section below to hide it."))
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                if manager.items.isEmpty {
                    Text(manager.isScanning ? L("Reading the menu bar…") : L("No icons found. Nexo needs Accessibility permission."))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(manager.items.enumerated()), id: \.element.id) { index, item in
                    itemRow(item, index: index)
                    if index < manager.items.count - 1 { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .overlay(sectionDropHighlight(.visible))
        .dropDestination(for: String.self) { payloads, _ in
            // An app dragged up from a hidden section becomes visible again.
            guard let id = payloads.first.flatMap(Self.appPayload) else { return false }
            manager.setSection(.visible, for: id)
            return true
        } isTargeted: { dropSection = $0 ? .visible : (dropSection == .visible ? nil : dropSection) }
    }

    private func itemRow(_ item: MenuBarItem, index: Int) -> some View {
        let targeted = dropItem == item.id
        let fromIndex = draggedItem.flatMap { id in manager.items.firstIndex { $0.id == id } }
        // Insertion line on the side the icon will land: above when it comes from further right.
        let lineOnTop = (fromIndex ?? 0) > index
        let module = item.canHide ? nil : SystemMenuItems.module(for: item)
        let draggable = item.canMove || module != nil
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(draggable ? .secondary : .quaternary)
            if let extra = item.systemExtra ?? (item.bundleID == SystemMenuItems.inputMenuOwner ? "" : nil) {
                systemIcon(module?.id ?? extra)
            } else {
                appIcon(item.switchID)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.displayName(item))
                if item.canMove && !item.title.isEmpty && item.title != item.appName {
                    Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if item.canHide {
                sectionPicker(item.switchID)
            } else if let module {
                sectionPicker(SystemSectionController.key(module.id))
            } else {
                Text(item.canMove ? L("Nexo") : L("Always shown")).font(.caption).foregroundStyle(.secondary)
                    .help(item.canMove ? "" : L("macOS does not let any app hide this icon."))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(draggedItem == item.id && manager.isMoving ? 0.4 : 1)
        .overlay(alignment: lineOnTop ? .top : .bottom) {
            if targeted && item.canMove { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .modifier(module.map { module in
            // macOS's own icons cannot be reordered, only dropped on a hidden section.
            ItemDrag(enabled: manager.isActive, payload: "app:" + SystemSectionController.key(module.id)) {}
        } ?? ItemDrag(enabled: item.canMove && manager.isActive && !manager.isMoving, payload: "item:" + item.id) {
            draggedItem = item.id
        })
        .dropDestination(for: String.self) { payloads, _ in
            dropItem = nil
            defer { draggedItem = nil }
            guard let id = payloads.first.flatMap(Self.itemPayload), let dragged = manager.items.first(where: { $0.id == id }) else { return false }
            manager.move(dragged, onto: item)
            return true
        } isTargeted: { dropItem = $0 ? item.id : (dropItem == item.id ? nil : dropItem) }
    }

    private static func displayName(_ item: MenuBarItem) -> String {
        if item.bundleID == SystemMenuItems.inputMenuOwner { return L("Input Menu") }
        guard let extra = item.systemExtra else { return item.appName }
        return SystemMenuItems.module(forExtra: extra)?.title ?? SystemMenuItems.fixedTitle(forExtra: extra) ?? item.appName
    }

    private func appSection(_ section: MenuBarSection, title: String, note: String) -> some View {
        let ids = appIDs(in: section)
        return GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 0) {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                if ids.isEmpty {
                    Text(L("No apps. Drag an icon here.")).foregroundStyle(.secondary)
                }
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        if let moduleID = SystemSectionController.moduleID(id) { systemIcon(moduleID) } else { appIcon(id) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.name(forKey: id))
                            if manager.controller.section(of: id) == .visible {
                                Text(L("Turned off in System Settings")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        sectionPicker(id)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .modifier(ItemDrag(enabled: manager.isActive && (manager.hasAccess || Self.isSystem(id)), payload: "app:" + id) {})
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .overlay(sectionDropHighlight(section))
        .dropDestination(for: String.self) { payloads, _ in
            dropSection = nil
            guard manager.isActive, let payload = payloads.first,
                  let id = Self.appPayload(payload) ?? Self.itemPayload(payload).flatMap({ id in manager.items.first { $0.id == id && $0.canHide }?.switchID }),
                  manager.hasAccess || Self.isSystem(id)
            else { return false }
            manager.setSection(section, for: id)
            return true
        } isTargeted: { dropSection = $0 ? section : (dropSection == section ? nil : dropSection) }
    }

    private func sectionDropHighlight(_ section: MenuBarSection) -> some View {
        RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).opacity(dropSection == section ? 1 : 0)
    }

    private static func itemPayload(_ payload: String) -> String? {
        payload.hasPrefix("item:") ? String(payload.dropFirst(5)) : nil
    }

    private static func appPayload(_ payload: String) -> String? {
        payload.hasPrefix("app:") ? String(payload.dropFirst(4)) : nil
    }

    /// Apps in a section; Always hidden also lists apps the user turned off in System Settings.
    private func appIDs(in section: MenuBarSection) -> [String] {
        var ids = Set(manager.controller.sections.filter { $0.value == section }.keys)
        if section == .alwaysHidden {
            let external = manager.states.filter { !$0.value && manager.controller.section(of: $0.key) == .visible }.keys
            ids.formUnion(external)
        }
        return ids.sorted { Self.name(forKey: $0).localizedCaseInsensitiveCompare(Self.name(forKey: $1)) == .orderedAscending }
    }

    private func sectionPicker(_ id: String) -> some View {
        let current = manager.controller.section(of: id) == .visible && manager.states[id] == false ? MenuBarSection.alwaysHidden : manager.controller.section(of: id)
        return Picker("", selection: Binding(get: { current }, set: { if $0 != current || $0 != manager.controller.section(of: id) { manager.setSection($0, for: id) } })) {
            Text(L("Visible")).tag(MenuBarSection.visible)
            Text(L("Hidden")).tag(MenuBarSection.hidden)
            Text(L("Always hidden")).tag(MenuBarSection.alwaysHidden)
        }
        .labelsHidden()
        .fixedSize()
        // macOS's own icons need no Full Disk Access.
        .disabled(!(manager.hasAccess || Self.isSystem(id)) || !manager.isActive)
    }

    private static func isSystem(_ key: String) -> Bool { SystemSectionController.moduleID(key) != nil }

    /// An app's name, or a macOS module's for `system:` keys.
    static func name(forKey key: String) -> String {
        guard let moduleID = SystemSectionController.moduleID(key) else { return appName(key) }
        return SystemMenuItems.modules.first { $0.id == moduleID }?.title ?? moduleID
    }

    private func systemIcon(_ id: String) -> some View {
        Image(systemName: SystemMenuItems.symbol(for: id)).frame(width: 18, height: 18).foregroundStyle(.secondary)
    }

    private func appIcon(_ bundleID: String) -> some View {
        Image(nsImage: Self.icon(bundleID)).resizable().frame(width: 18, height: 18)
    }

    private static func appURL(_ id: String) -> URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    static func appName(_ id: String) -> String {
        guard let url = appURL(id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func icon(_ id: String) -> NSImage {
        guard let url = appURL(id) else { return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Makes a row draggable only when it can move; `onStart` records which row is in flight.
private struct ItemDrag: ViewModifier {
    let enabled: Bool
    let payload: String
    let onStart: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                onStart()
                return NSItemProvider(object: payload as NSString)
            }
        } else {
            content
        }
    }
}

/// macOS's own modules: shown or hidden only (they have no per-app switch, so no temporary reveal).
private struct SystemItemsSection: View {
    @ObservedObject var manager: MenuBarManager
    @State private var shown = Self.currentStates()

    /// Off and not in one of Nexo's hidden sections (those are listed there).
    private var offModules: [SystemMenuItems.Module] {
        SystemMenuItems.modules.filter { shown[$0.id] == false && manager.controller.sections[SystemSectionController.key($0.id)] == nil }
    }

    private static func currentStates() -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: SystemMenuItems.modules.map { ($0.id, SystemMenuItems.isShown($0)) })
    }

    var body: some View {
        GroupBox(label: Text(L("System items")).font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("macOS icons that are switched off. Switch one on to add it to the menu bar; from the list above you can then move it to Hidden like any other icon."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if offModules.isEmpty {
                    Text(L("Every macOS icon is in the menu bar.")).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(offModules) { module in
                        Toggle(module.title, isOn: Binding(get: { shown[module.id] ?? false }, set: { value in
                            manager.setSystemModule(module, shown: value)
                            shown[module.id] = value
                        }))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        // Hidden from a row above, or changed in System Settings: re-read on every scan.
        .onReceive(manager.$items) { _ in shown = Self.currentStates() }
    }
}
