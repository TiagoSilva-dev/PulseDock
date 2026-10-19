import AgentBridge
import AgentCore
import AppKit
import Diagnostics
import DockCore
import DockRendering
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $model.selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(232)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch model.selection {
                case .general: GeneralPane(model: model)
                case .appearance: AppearancePane(model: model)
                case .dockBehavior: DockBehaviorPane(model: model)
                case .agents: AgentsPane(model: model)
                case .notifications: NotificationsPane(model: model)
                case .privacy: PrivacyPane(model: model)
                case .advanced: AdvancedPane(model: model)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.selection.title)
        }
        .sheet(item: $model.installSheet) { _ in InstallSheetView(model: model) }
        .sheet(isPresented: $model.managedTaskSheetVisible) { ManagedTaskSheet(model: model) }
        .alert(tr("settings.message", "PulseDock"), isPresented: Binding(get: { model.lastMessage != nil }, set: { if !$0 { model.lastMessage = nil } })) {
            Button(tr("common.ok", "OK")) { model.lastMessage = nil }
        } message: {
            Text(model.lastMessage ?? "")
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

/// Binding into the settings store.
@MainActor
func setting<Value>(_ store: SettingsStore, _ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding(get: { store.settings[keyPath: keyPath] }, set: { value in store.update { $0[keyPath: keyPath] = value } })
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let store = model.settings
        Form {
            Section(tr("settings.general.startup", "Startup")) {
                Toggle(tr("settings.general.launchAtLogin", "Open PulseDock at login"), isOn: Binding(
                    get: { model.loginItemState == .enabled || model.loginItemState == .requiresApproval },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if model.loginItemState == .requiresApproval {
                    HStack {
                        Text(tr("settings.general.loginApproval", "macOS needs your approval in Login Items."))
                            .foregroundStyle(.secondary)
                        Button(tr("settings.general.openLoginItems", "Open Login Items")) { LoginItem.openSystemSettings() }
                    }
                }
            }
            Section {
                Picker(tr("settings.general.mode", "Mode"), selection: Binding(
                    get: { store.settings.general.operatingMode },
                    set: { mode in
                        if mode == .replacement { model.confirmReplacementMode() } else { model.setOperatingMode(.companion) }
                    }
                )) {
                    Text(tr("settings.general.mode.companion", "Companion")).tag(OperatingMode.companion)
                    Text(tr("settings.general.mode.replacement", "Replacement")).tag(OperatingMode.replacement)
                }
                .pickerStyle(.segmented)
                Text(store.settings.general.operatingMode == .companion
                     ? tr("settings.general.mode.companionHelp", "PulseDock works alongside the macOS Dock and does not change any system setting.")
                     : tr("settings.general.mode.replacementHelp", "The macOS Dock is set to auto-hide. Switch back to Companion to restore it exactly as it was."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(tr("settings.general.operation", "How PulseDock runs"))
            }
            Section(tr("settings.general.language", "Language")) {
                Picker(tr("settings.general.language.picker", "Interface language"), selection: setting(store, \.general.language)) {
                    Text(tr("settings.general.language.system", "System default")).tag(LanguagePreference.system)
                    Text("English").tag(LanguagePreference.english)
                    Text("Português (Brasil)").tag(LanguagePreference.portuguese)
                }
                HStack {
                    Text(tr("settings.general.language.restart", "Takes effect the next time PulseDock opens."))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("settings.general.relaunch", "Relaunch Now")) { Relaunch.now() }
                }
            }
            Section(tr("settings.general.menuBar", "Menu bar")) {
                Toggle(tr("settings.general.showMenuBar", "Show PulseDock in the menu bar"), isOn: setting(store, \.general.showMenuBarItem))
                if !store.settings.general.showMenuBarItem {
                    Text(tr("settings.general.menuBarHidden", "You can still open Settings by right-clicking an empty area of the dock."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            WorkspacesSection(model: model)
        }
        .onAppear { model.loginItemState = LoginItem.state }
    }
}

private struct WorkspacesSection: View {
    @Bindable var model: SettingsModel
    private let symbols = ["chevron.left.forwardslash.chevron.right", "paintpalette", "house", "scope", "briefcase", "gamecontroller", "book", "music.note", "camera", "leaf"]

    var body: some View {
        let store = model.settings
        Section {
            ForEach(Array(store.settings.workspaces.enumerated()), id: \.element.id) { index, workspace in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Menu {
                            ForEach(symbols, id: \.self) { symbol in
                                Button { store.update { $0.workspaces[index].symbol = symbol } } label: { Image(systemName: symbol) }
                            }
                        } label: { Image(systemName: workspace.symbol) }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        TextField(tr("settings.workspace.name", "Name"), text: Binding(
                            get: { store.settings.workspaces[safe: index]?.displayName ?? "" },
                            set: { name in store.update { if $0.workspaces.indices.contains(index) { $0.workspaces[index].displayName = name } } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        if workspace.id == store.settings.activeWorkspace?.id {
                            Text(tr("settings.workspace.active", "Active")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button(tr("settings.workspace.switch", "Switch")) { model.services.dockController.switchWorkspace(to: workspace.id) }
                        }
                        if workspace.preset != nil {
                            Button {
                                store.update { settings in
                                    if let i = settings.workspaces.firstIndex(where: { $0.id == workspace.id }) { WorkspaceDefaults.restore(&settings.workspaces[i]) }
                                }
                            } label: { Image(systemName: "arrow.counterclockwise") }
                                .buttonStyle(.borderless)
                                .help(tr("settings.workspace.restore", "Restore this workspace's default apps and widgets"))
                                .accessibilityLabel(tr("settings.workspace.restore", "Restore this workspace's default apps and widgets"))
                        }
                        Button(role: .destructive) {
                            store.update { settings in
                                settings.workspaces.removeAll { $0.id == workspace.id }
                                if settings.activeWorkspaceID == workspace.id { settings.activeWorkspaceID = settings.workspaces.first?.id }
                            }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(store.settings.workspaces.count <= 1)
                    }
                    HStack(spacing: 14) {
                        Picker(tr("settings.workspace.theme", "Theme"), selection: Binding(
                            get: { store.settings.workspaces[safe: index]?.theme },
                            set: { theme in store.update { if $0.workspaces.indices.contains(index) { $0.workspaces[index].theme = theme } } }
                        )) {
                            Text(tr("settings.workspace.theme.default", "Default")).tag(ThemeID?.none)
                            ForEach(ThemeID.allCases) { Text($0.displayName).tag(ThemeID?.some($0)) }
                        }
                        Picker(tr("settings.workspace.agents", "AI sessions"), selection: Binding(
                            get: { store.settings.workspaces[safe: index]?.agentFilter ?? .all },
                            set: { filter in store.update { if $0.workspaces.indices.contains(index) { $0.workspaces[index].agentFilter = filter } } }
                        )) {
                            Text(tr("settings.workspace.agents.all", "All")).tag(AgentFilter.all)
                            Text(tr("settings.workspace.agents.attention", "Only when they need me")).tag(AgentFilter.attentionOnly)
                            Text(tr("settings.workspace.agents.hidden", "Hidden")).tag(AgentFilter.hidden)
                        }
                        Toggle(tr("settings.workspace.running", "Running apps"), isOn: Binding(
                            get: { store.settings.workspaces[safe: index]?.showRunningApps ?? true },
                            set: { value in store.update { if $0.workspaces.indices.contains(index) { $0.workspaces[index].showRunningApps = value } } }
                        ))
                    }
                    .font(.callout)
                    Text(tr("settings.workspace.summary", "Pinned: %ld · Widgets: %ld", workspace.pinned.count, workspace.widgets.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button(tr("settings.workspace.add", "Add Workspace")) {
                    store.update { settings in
                        let finder = PinnedItem.application(bundleIdentifier: "com.apple.finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
                        settings.workspaces.append(Workspace(name: tr("settings.workspace.new", "New Workspace"), symbol: "briefcase", pinned: [finder], theme: nil,
                                                             widgets: [WidgetPlacement(kind: .clock)], showRunningApps: true, agentFilter: .all))
                    }
                }
                Spacer()
                Button(tr("settings.workspace.import", "Rebuild from macOS Dock")) {
                    store.update { settings in
                        settings.updateActiveWorkspace { workspace in
                            workspace.pinned = SystemDockImporter.persistentApps().map { PinnedItem.application(bundleIdentifier: $0.bundleIdentifier, url: $0.url) }
                        }
                    }
                }
            }
        } header: {
            Text(tr("settings.workspaces", "Workspaces"))
        } footer: {
            Text(tr("settings.workspaces.footer", "Each workspace has its own pinned apps, order, theme, widgets and AI filter. Switching never moves or hides other apps' windows. Shortcut: %@.", HotKeys.Action.nextWorkspace.displayShortcut))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let store = model.settings
        Form {
            Section(tr("settings.appearance.theme", "Theme")) {
                HStack(spacing: 14) {
                    ForEach(ThemeID.allCases) { theme in
                        ThemeCard(theme: theme, isSelected: store.settings.appearance.theme == theme, accessibility: model.services.accessibility)
                            .onTapGesture { store.update { $0.appearance.theme = theme } }
                    }
                }
                .padding(.vertical, 6)
            }
            Section(tr("settings.appearance.size", "Size")) {
                LabeledSlider(title: tr("settings.appearance.iconSize", "Icon size"), value: setting(store, \.appearance.iconSize), range: 40...80, step: 1, format: "%.0f pt")
                Picker(tr("settings.appearance.spacing", "Spacing"), selection: setting(store, \.appearance.spacing)) {
                    Text(tr("settings.appearance.spacing.compact", "Compact")).tag(SpacingStyle.compact)
                    Text(tr("settings.appearance.spacing.standard", "Standard")).tag(SpacingStyle.standard)
                    Text(tr("settings.appearance.spacing.comfortable", "Comfortable")).tag(SpacingStyle.comfortable)
                }
                .pickerStyle(.segmented)
            }
            Section(tr("settings.appearance.magnification", "Magnification")) {
                Toggle(tr("settings.appearance.magnify", "Magnify icons under the pointer"), isOn: setting(store, \.appearance.magnificationEnabled))
                LabeledSlider(title: tr("settings.appearance.maxScale", "Maximum scale"), value: setting(store, \.appearance.maxMagnification), range: 1.1...2.0, step: 0.05, format: "%.2f×")
                    .disabled(!store.settings.appearance.magnificationEnabled)
            }
            Section(tr("settings.appearance.material", "Material")) {
                Picker(tr("settings.appearance.transparency", "Transparency"), selection: setting(store, \.appearance.transparency)) {
                    Text(tr("settings.appearance.transparency.clear", "Clear")).tag(TransparencyLevel.clear)
                    Text(tr("settings.appearance.transparency.standard", "Standard")).tag(TransparencyLevel.standard)
                    Text(tr("settings.appearance.transparency.opaque", "Opaque")).tag(TransparencyLevel.opaque)
                }
                .pickerStyle(.segmented)
                Picker(tr("settings.appearance.border", "Border"), selection: setting(store, \.appearance.border)) {
                    Text(tr("settings.appearance.border.none", "None")).tag(BorderStyle.none)
                    Text(tr("settings.appearance.border.subtle", "Subtle")).tag(BorderStyle.subtle)
                    Text(tr("settings.appearance.border.defined", "Defined")).tag(BorderStyle.defined)
                }
                .pickerStyle(.segmented)
                if model.services.accessibility.reduceTransparency {
                    Label(tr("settings.appearance.reduceTransparency", "Reduce Transparency is on in System Settings, so PulseDock uses opaque surfaces."), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section(tr("settings.appearance.details", "Details")) {
                Toggle(tr("settings.appearance.animations", "Animations"), isOn: setting(store, \.appearance.animationsEnabled))
                Toggle(tr("settings.appearance.labels", "Show names when hovering"), isOn: setting(store, \.appearance.showHoverLabels))
                Toggle(tr("settings.appearance.indicators", "Show indicators for running apps"), isOn: setting(store, \.appearance.showRunningIndicators))
                if model.services.accessibility.reduceMotion {
                    Label(tr("settings.appearance.reduceMotion", "Reduce Motion is on: PulseDock replaces movement with quick fades."), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            WidgetsSection(model: model)
            CollectionsSection(model: model)
        }
    }
}

private struct ThemeCard: View {
    let theme: ThemeID
    let isSelected: Bool
    let accessibility: AccessibilityOptions
    @Environment(\.colorScheme) private var systemScheme

    /// The island as each theme draws it: Aurora's luminous accent, the others' state colour.
    @ViewBuilder
    private func islandSample(_ palette: Theme) -> some View {
        if palette.ambientIntensity >= 1, let glow = palette.accentGradient.first {
            Capsule()
                .fill(LinearGradient(colors: palette.accentGradient, startPoint: .leading, endPoint: .trailing))
                .frame(width: 24, height: 10)
                .shadow(color: glow.opacity(0.9), radius: 5)
        } else {
            Capsule().fill(palette.tone(.working)).frame(width: 22, height: 10)
        }
    }

    var body: some View {
        let palette = Theme.theme(for: theme)
        VStack(spacing: 8) {
            ZStack {
                LinearGradient(colors: [Color(.sRGB, red: 0.35, green: 0.42, blue: 0.62), Color(.sRGB, red: 0.72, green: 0.52, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing)
                PulseGlassSurface(theme: palette, cornerRadius: 10, accessibility: accessibility, showsShadow: true)
                    .frame(width: 120, height: 30)
                    .overlay {
                        HStack(spacing: 5) {
                            ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.75)).frame(width: 16, height: 16) }
                            islandSample(palette)
                        }
                    }
                    .environment(\.colorScheme, palette.forcedColorScheme ?? systemScheme)
            }
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2.5 : 1))
            Text(theme.displayName).font(.callout.weight(isSelected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct WidgetsSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let store = model.settings
        let widgets = store.activeWorkspace.widgets
        Section {
            if widgets.isEmpty {
                Text(tr("settings.widgets.none", "No widgets in this workspace.")).foregroundStyle(.secondary)
            }
            ForEach(Array(widgets.enumerated()), id: \.element.id) { index, placement in
                HStack {
                    Image(systemName: placement.kind.symbol).frame(width: 18).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(placement.kind == .quickLaunch
                             ? (store.settings.collections.first { $0.id == placement.collectionID }?.name ?? placement.kind.displayName)
                             : placement.kind.displayName)
                        Text(placement.kind.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(index == widgets.count - 1)
                    Button(role: .destructive) {
                        store.update { $0.updateActiveWorkspace { $0.widgets.removeAll { $0.id == placement.id } } }
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Menu(tr("settings.widgets.add", "Add Widget")) {
                ForEach(WidgetCategory.allCases, id: \.self) { category in
                    let kinds = WidgetKind.addable.filter { $0.category == category }
                    if !kinds.isEmpty {
                        Menu {
                            ForEach(kinds) { kind in
                                Button { model.services.dockController.addWidget(kind) } label: { Label(kind.displayName, systemImage: kind.symbol) }
                                    .help(kind.summary)
                            }
                        } label: {
                            Label(category.displayName, systemImage: category.symbol)
                        }
                    }
                }
                if !store.settings.collections.isEmpty { Divider() }
                ForEach(store.settings.collections) { collection in
                    Button(collection.name) { model.services.dockController.addWidget(.quickLaunch, collection: collection.id) }
                }
            }
            .fixedSize()
        } header: {
            Text(tr("settings.widgets", "Widgets in “%@”", store.activeWorkspace.displayName))
        }
    }

    private func move(_ index: Int, by offset: Int) {
        model.settings.update { settings in
            settings.updateActiveWorkspace { workspace in
                let target = index + offset
                guard workspace.widgets.indices.contains(index), workspace.widgets.indices.contains(target) else { return }
                workspace.widgets.swapAt(index, target)
            }
        }
    }
}

private struct CollectionsSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let store = model.settings
        Section {
            ForEach(Array(store.settings.collections.enumerated()), id: \.element.id) { index, collection in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField(tr("settings.collections.name", "Name"), text: Binding(
                            get: { store.settings.collections[safe: index]?.name ?? "" },
                            set: { name in store.update { if $0.collections.indices.contains(index) { $0.collections[index].name = name } } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button(tr("settings.collections.addItems", "Add Items…")) { addItems(to: index) }
                        Button(role: .destructive) {
                            store.update { settings in
                                settings.collections.removeAll { $0.id == collection.id }
                                for workspaceIndex in settings.workspaces.indices {
                                    settings.workspaces[workspaceIndex].widgets.removeAll { $0.collectionID == collection.id }
                                }
                            }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    ForEach(collection.items) { item in
                        HStack {
                            Image(nsImage: IconProvider.shared.icon(forPath: item.path)).resizable().frame(width: 16, height: 16)
                            Text((item.path as NSString).lastPathComponent).font(.callout)
                            Spacer()
                            Button { store.update { $0.collections[index].items.removeAll { $0.id == item.id } } } label: {
                                Image(systemName: "xmark.circle")
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Button(tr("settings.collections.new", "New Collection")) {
                store.update { $0.collections.append(QuickLaunchCollection(name: tr("settings.collections.default", "Collection"), symbol: "square.grid.2x2", items: [])) }
            }
        } header: {
            Text(tr("settings.collections", "Quick Launch collections"))
        } footer: {
            Text(tr("settings.collections.footer", "A collection is a dock item that opens a grid of apps, folders and files. Add it from “Add Widget”."))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addItems(to index: Int) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let items = panel.urls.map { url in
            url.pathExtension == "app" ? PinnedItem.application(bundleIdentifier: Bundle(url: url)?.bundleIdentifier, url: url) : PinnedItem.folder(url)
        }
        model.settings.update { settings in
            guard settings.collections.indices.contains(index) else { return }
            settings.collections[index].items.append(contentsOf: items)
        }
    }
}

// MARK: - Dock behavior

private struct DockBehaviorPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let store = model.settings
        Form {
            Section(tr("settings.behavior.visibility", "Visibility")) {
                Toggle(tr("settings.behavior.autoHide", "Automatically hide and show the dock"), isOn: setting(store, \.behavior.autoHide))
                LabeledSlider(title: tr("settings.behavior.revealDelay", "Show after"), value: setting(store, \.behavior.revealDelay), range: 0...2, step: 0.05, format: "%.2f s")
                    .disabled(!store.settings.behavior.autoHide)
                LabeledSlider(title: tr("settings.behavior.hideDelay", "Hide after"), value: setting(store, \.behavior.hideDelay), range: 0.1...3, step: 0.1, format: "%.1f s")
                    .disabled(!store.settings.behavior.autoHide)
                Toggle(tr("settings.behavior.fullScreen", "Stay out of the way of full-screen apps and games"), isOn: setting(store, \.behavior.avoidFullScreenApps))
            }
            Section(tr("settings.behavior.position", "Position")) {
                Picker(tr("settings.behavior.display", "Display"), selection: setting(store, \.behavior.display)) {
                    Text(tr("settings.behavior.display.primary", "Main display")).tag(DisplayPreference.primary)
                    Text(tr("settings.behavior.display.follow", "Follow the pointer")).tag(DisplayPreference.followPointer)
                    ForEach(DisplayLocator.displays()) { display in
                        Text(display.name).tag(DisplayPreference.specific(uuid: display.uuid, name: display.name))
                    }
                }
                LabeledSlider(title: tr("settings.behavior.margin", "Distance from the bottom"), value: setting(store, \.behavior.bottomMargin), range: 0...40, step: 1, format: "%.0f pt")
                Text(tr("settings.behavior.positionNote", "PulseDock sits at the bottom of the screen. With the macOS Dock visible at the bottom, PulseDock stays just above it."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(tr("settings.behavior.items", "Items")) {
                Toggle(tr("settings.behavior.trash", "Show Trash"), isOn: setting(store, \.behavior.showTrash))
                Button(tr("settings.behavior.addApp", "Add Application…")) { model.services.dockController.chooseApplicationToPin() }
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let store = model.settings
        Form {
            Section {
                Toggle(tr("settings.notifications.enabled", "Notify me about agent events"), isOn: setting(store, \.notifications.enabled))
                HStack {
                    Text(authorizationText).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("settings.notifications.test", "Send Test")) { model.sendTestNotification() }
                    Button(tr("settings.notifications.system", "System Settings…")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
            Section(tr("settings.notifications.types", "What to notify")) {
                Toggle(tr("settings.notifications.attention", "Approvals and questions (recommended)"), isOn: setting(store, \.notifications.attention))
                Toggle(tr("settings.notifications.failures", "Failed turns"), isOn: setting(store, \.notifications.failures))
                Toggle(tr("settings.notifications.completions", "Finished turns"), isOn: setting(store, \.notifications.completions))
                Toggle(tr("settings.notifications.usage", "Claude usage limits at 80% and 95%"), isOn: setting(store, \.notifications.usageLimits))
                Toggle(tr("settings.notifications.sound", "Play a sound"), isOn: setting(store, \.notifications.playSound))
                Text(tr("settings.notifications.grouping", "Requests that arrive together are grouped into a single notification."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(tr("settings.notifications.quiet", "Quiet hours")) {
                Toggle(tr("settings.notifications.quietEnabled", "Silence notifications during quiet hours"), isOn: setting(store, \.notifications.quietHoursEnabled))
                HStack {
                    DatePicker(tr("settings.notifications.from", "From"), selection: minuteBinding(\.notifications.quietStart), displayedComponents: .hourAndMinute)
                    DatePicker(tr("settings.notifications.to", "To"), selection: minuteBinding(\.notifications.quietEnd), displayedComponents: .hourAndMinute)
                }
                .disabled(!store.settings.notifications.quietHoursEnabled)
            }
        }
        .onAppear { model.refreshNotificationAuthorization() }
    }

    private var authorizationText: String {
        switch model.notificationAuthorization {
        case .authorized, .provisional, .ephemeral: tr("settings.notifications.allowed", "Allowed by macOS")
        case .denied: tr("settings.notifications.denied", "Turned off in System Settings")
        default: tr("settings.notifications.notAsked", "macOS will ask the first time")
        }
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(model.settings.settings[keyPath: keyPath]) * 60) },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.settings.update { $0[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0) }
            }
        )
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let store = model.settings
        Form {
            Section {
                Toggle(tr("settings.privacy.mode", "Privacy Mode"), isOn: setting(store, \.privacy.privacyMode))
                Text(tr("settings.privacy.modeHelp", "Hides project names, paths and task details everywhere (dock, cards, Mission Control, notifications). Shortcut: %@.", HotKeys.Action.togglePrivacy.displayShortcut))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(tr("settings.privacy.capture", "What the hook helper keeps")) {
                Picker(tr("settings.privacy.commands", "Shell commands"), selection: setting(store, \.privacy.commandDetail)) {
                    Text(tr("settings.privacy.commands.redacted", "Command line, credentials removed")).tag(SanitizerOptions.CommandDetail.redacted)
                    Text(tr("settings.privacy.commands.program", "Program name only")).tag(SanitizerOptions.CommandDetail.program)
                    Text(tr("settings.privacy.commands.none", "Nothing")).tag(SanitizerOptions.CommandDetail.none)
                }
                Toggle(tr("settings.privacy.filePaths", "File paths of tool calls"), isOn: setting(store, \.privacy.keepFilePaths))
                Toggle(tr("settings.privacy.queries", "Search patterns and web queries"), isOn: setting(store, \.privacy.keepSearchQueries))
                Text(tr("settings.privacy.never", "Never kept: prompts, file contents, command output, diffs, assistant messages, environment variables, credentials."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(tr("settings.privacy.history", "History on this Mac")) {
                Toggle(tr("settings.privacy.storeHistory", "Keep a history of sessions and events"), isOn: setting(store, \.privacy.storeHistory))
                Toggle(tr("settings.privacy.storePaths", "Keep full project paths in the history"), isOn: setting(store, \.privacy.storePaths))
                    .disabled(!store.settings.privacy.storeHistory)
                Stepper(value: setting(store, \.privacy.retentionDays), in: 1...90) {
                    Text(trp("settings.privacy.retention", one: "Delete history after %ld day", other: "Delete history after %ld days", store.settings.privacy.retentionDays))
                }
                if let stats = model.databaseStatistics {
                    Text(tr("settings.privacy.stats", "Sessions: %ld · Events: %ld · On disk: %@", stats.sessions, stats.events, ByteCountFormatter.string(fromByteCount: stats.fileBytes, countStyle: .file)))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button(tr("settings.privacy.delete", "Delete History…"), role: .destructive) { model.deleteHistory() }
            }
            Section {
                Text(tr("settings.privacy.local", "PulseDock works entirely on this Mac. It sends nothing to any server."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.refreshStatistics() }
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let store = model.settings
        let services = model.services
        Form {
            Section(tr("settings.advanced.diagnostics", "Diagnostics")) {
                LabeledContent(tr("settings.advanced.bridge", "Local socket"), value: bridgeText)
                LabeledContent(tr("settings.advanced.helper", "Hook helper"), value: services.bridge.helperInstalled ? tr("settings.advanced.helper.ok", "Installed") : tr("settings.advanced.helper.missing", "Not installed"))
                LabeledContent(tr("settings.advanced.events", "Events received"), value: "\(services.bridge.statistics?.accepted ?? 0)")
                LabeledContent(tr("settings.advanced.memory", "PulseDock memory"), value: ProcessMetrics.physicalFootprint().map(ProcessMetrics.formattedBytes) ?? "—")
                ForEach(AgentProvider.allCases.filter { $0 != .demo }, id: \.self) { provider in
                    LabeledContent(tr("settings.advanced.lastEvent", "Last %@ event", provider.displayName),
                                   value: services.agents.lastEventAt[provider].map { Formatting.relative($0) } ?? "—")
                }
                HStack {
                    Button(tr("settings.advanced.export", "Export Sanitized Diagnostics…")) { model.exportDiagnostics() }
                    Button(tr("settings.advanced.openFolder", "Open Data Folder")) { model.openDataFolder() }
                }
            }
            Section(tr("settings.advanced.demo", "Demo")) {
                Toggle(tr("settings.advanced.demoMode", "Demo Mode (simulated sessions, clearly labelled)"), isOn: Binding(
                    get: { model.services.agents.isDemoRunning },
                    set: { enabled in
                        store.update { $0.advanced.demoMode = enabled }
                        model.services.agents.setDemo(enabled)
                    }
                ))
                Text(tr("settings.advanced.demoHelp", "Demo sessions are marked DEMO and are never saved to the history."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(tr("settings.advanced.compatibility", "Compatibility")) {
                Toggle(tr("settings.advanced.legacyMaterial", "Use the macOS 15 material"), isOn: setting(store, \.advanced.forceLegacyMaterial))
            }
            Section(tr("settings.advanced.restore", "Restore")) {
                Button(tr("settings.advanced.restoreDock", "Restore the macOS Dock")) { model.restoreSystemDock() }
                    .disabled(!model.replacement.hasRestorePoint && store.settings.general.operatingMode == .companion)
                Button(tr("settings.advanced.removeHooks", "Remove All PulseDock Hooks…")) { model.removeAllHooks() }
                Button(tr("settings.advanced.reset", "Reset Settings…"), role: .destructive) { model.resetSettings() }
            }
        }
    }

    private var bridgeText: String {
        switch model.services.bridge.status {
        case .listening: tr("settings.advanced.bridge.listening", "Listening")
        case .stopped: tr("settings.advanced.bridge.stopped", "Stopped")
        case let .failed(message): message
        }
    }
}

// MARK: - Shared controls

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        HStack {
            Text(title)
            // Quantized through the binding instead of `step:`, which draws one tick per step.
            Slider(value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, ($0 / step).rounded() * step)) }), in: range)
            Text(String(format: format, locale: Locale.current, value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum Relaunch {
    /// Starts a detached shell that waits for this process to exit, then reopens the app, so
    /// the new instance never races the old one for the local socket.
    static func now() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open '\(path)'"]
        try? process.run()
        NSApp.terminate(nil)
    }
}
