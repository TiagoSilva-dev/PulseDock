import AdapterSupport
import AgentCore
import AppKit
import ClaudeCodeAdapter
import CodexAdapter
import DockRendering
import SwiftUI

struct AgentsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let store = model.settings
        let integrations = model.integrations
        Form {
            Section {
                Toggle(tr("settings.agents.enabled", "Show Agent Pulse in the dock"), isOn: setting(store, \.agents.enabled))
            }
            Section {
                IntegrationCard(
                    provider: .claudeCode,
                    detail: claudeDetail,
                    state: integrations.connectionState(for: .claudeCode),
                    isRefreshing: integrations.isRefreshing
                ) {
                    switch integrations.claudeStatus {
                    case .notInstalled:
                        Button(tr("settings.agents.connect", "Connect…")) { model.prepare(.claudeInstall) }
                            .buttonStyle(.borderedProminent)
                            .disabled(integrations.claude?.isInstalled != true)
                    case .installed:
                        Button(tr("settings.agents.test", "Test Connection")) { model.runSelfTest() }
                        Button(tr("settings.agents.disconnect", "Disconnect…")) { model.prepare(.claudeUninstall) }
                    case .incomplete, .outdated:
                        Button(tr("settings.agents.repair", "Repair…")) { model.prepare(.claudeInstall) }
                            .buttonStyle(.borderedProminent)
                        Button(tr("settings.agents.disconnect", "Disconnect…")) { model.prepare(.claudeUninstall) }
                    case .unreadable:
                        Button(tr("settings.agents.openSettingsFile", "Open settings.json")) {
                            NSWorkspace.shared.open(integrations.claudeInstaller.settingsURL)
                        }
                    }
                }
                if let result = model.selfTestResult {
                    Label(result ? tr("settings.agents.test.ok", "The hook helper reached PulseDock.") : tr("settings.agents.test.failed", "The helper could not reach PulseDock. Check Diagnostics in Advanced."),
                          systemImage: result ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result ? Theme.nativeGlass.tone(.success) : Theme.nativeGlass.tone(.failure))
                        .font(.callout)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text(tr("settings.agents.claude.footer", "Uses the official hooks of Claude Code (user settings). PulseDock observes sessions; approvals are always answered in Claude Code itself."))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                IntegrationCard(
                    provider: .codex,
                    detail: codexDetail,
                    state: integrations.connectionState(for: .codex),
                    isRefreshing: integrations.isRefreshing
                ) {
                    if integrations.codexHookEvents.isEmpty {
                        Button(tr("settings.agents.connectHooks", "Connect with Hooks…")) { model.prepare(.codexHooksInstall) }
                            .buttonStyle(.borderedProminent)
                            .disabled(integrations.codex?.isInstalled != true)
                    } else {
                        Button(tr("settings.agents.disconnectHooks", "Disconnect Hooks…")) { model.prepare(.codexHooksUninstall) }
                    }
                    Menu(tr("settings.agents.more", "More")) {
                        if integrations.codexNotifyInstalled {
                            Button(tr("settings.agents.notify.remove", "Remove notify integration")) {
                                Task { try? await integrations.uninstallCodexNotify() }
                            }
                        } else {
                            Button(tr("settings.agents.notify.install", "Use notify instead (turn end only)…")) { model.prepareCodexNotify() }
                        }
                        Button(tr("settings.agents.codex.newTask", "Start a Managed Codex Task…")) { model.managedTaskSheetVisible = true }
                            .disabled(integrations.codex?.isInstalled != true)
                    }
                    .fixedSize()
                }
                if integrations.connectionState(for: .codex) == .awaitingTrust {
                    Label(tr("settings.agents.codex.trust", "Open Codex and run /hooks to review and trust the PulseDock hooks. Codex skips hooks until you do."),
                          systemImage: "hand.raised")
                        .font(.callout)
                        .foregroundStyle(Theme.nativeGlass.tone(.attention))
                }
            } header: {
                Text("Codex")
            } footer: {
                Text(tr("settings.agents.codex.footer", "Observe Mode follows Codex sessions you start in a terminal (hooks, or notify for turn endings only). Managed Mode starts tasks through the official app-server, which also lets PulseDock show approval decisions."))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section(tr("settings.agents.reliability", "State reliability")) {
                Stepper(value: setting(store, \.agents.workingQuietLimitMinutes), in: 2...60, step: 1) {
                    Text(tr("settings.agents.quietLimit", "Mark “working” as stale after %ld min without events", Int(store.settings.agents.workingQuietLimitMinutes)))
                }
                Stepper(value: setting(store, \.agents.toolQuietLimitMinutes), in: 10...240, step: 5) {
                    Text(tr("settings.agents.toolLimit", "…or after %ld min while a command is running", Int(store.settings.agents.toolQuietLimitMinutes)))
                }
                Toggle(tr("settings.agents.registry", "Discover Claude Code sessions already running"), isOn: setting(store, \.agents.useSessionRegistry))
                Text(tr("settings.agents.registryHelp", "Reads Claude Code's local session list (process, folder and name only) to find sessions that started before PulseDock. It never decides a state from it."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(tr("settings.agents.presentation", "Presentation")) {
                LabeledSlider(title: tr("settings.agents.peekDelay", "Quick Peek after"), value: setting(store, \.agents.quickPeekDelay), range: 0.2...2, step: 0.1, format: "%.1f s")
                Toggle(tr("settings.agents.flash", "Briefly confirm finished turns in the dock"), isOn: setting(store, \.agents.showCompletionFlash))
            }
        }
        .task { await integrations.refresh() }
    }

    private var claudeDetail: String {
        guard let claude = model.integrations.claude else { return tr("settings.agents.detectingClaude", "Looking for Claude Code…") }
        guard let path = claude.executablePath else { return tr("settings.agents.claude.notFound", "Claude Code was not found in the usual install locations.") }
        let version = claude.version.map { " · \($0)" } ?? ""
        return (Formatting.shortPath(path) ?? path) + version
    }

    private var codexDetail: String {
        guard let codex = model.integrations.codex else { return tr("settings.agents.detectingCodex", "Looking for Codex…") }
        guard let path = codex.executablePath else { return tr("settings.agents.codex.notFound", "Codex CLI was not found. Install it, then come back here.") }
        let version = codex.version.map { " · \($0)" } ?? ""
        return (Formatting.shortPath(path) ?? path) + version
    }
}

private struct IntegrationCard<Actions: View>: View {
    let provider: AgentProvider
    let detail: String
    let state: IntegrationsManager.ConnectionState
    let isRefreshing: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentGlyph(provider: provider, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.displayName).font(.headline)
                    IntegrationChip(provider: provider, state: state, theme: .nativeGlass, showsProvider: false)
                    if isRefreshing { ProgressView().controlSize(.mini) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if case let .needsAttention(message) = state {
                    Text(message).font(.callout).foregroundStyle(Theme.nativeGlass.tone(.attention))
                }
                if case let .receiving(date) = state {
                    Text(tr("settings.agents.lastEvent", "Last event %@", Formatting.relative(date))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack { actions }.controlSize(.regular)
        }
        .padding(.vertical, 4)
    }
}

/// Preview → consent → apply, with the exact diff of the configuration file.
struct InstallSheetView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        if let sheet = model.installSheet {
            VStack(alignment: .leading, spacing: 14) {
                Text(sheet.title).font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sheet.explanation, id: \.self) { line in
                        Label(line, systemImage: "checkmark.shield").font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(sheet.plan.fileURL.path).font(PulseTypography.mono).textSelection(.enabled)
                    if sheet.plan.originalText == nil { Text(tr("install.newFile", "(new file)")).foregroundStyle(.secondary) }
                }
                .font(.callout)
                Text(tr("install.counts", "PulseDock events: %ld · Other handlers kept: %ld · Earlier PulseDock handlers replaced: %ld",
                        sheet.plan.addedEvents.count, sheet.plan.preservedForeignHandlers, sheet.plan.removedHandlers))
                    .font(.caption).foregroundStyle(.secondary)
                DiffView(lines: sheet.plan.previewLines)
                    .frame(minHeight: 220)
                if let error = sheet.error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.nativeGlass.tone(.failure)).font(.callout)
                }
                if sheet.done {
                    Label(doneMessage(sheet), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.nativeGlass.tone(.success))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if sheet.done, case .claudeInstall = sheet.target {
                        Button(tr("settings.agents.test", "Test Connection")) { model.runSelfTest() }
                    }
                    Spacer()
                    if sheet.done {
                        Button(tr("common.done", "Done")) { model.installSheet = nil }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(tr("common.cancel", "Cancel")) { model.installSheet = nil }.keyboardShortcut(.cancelAction)
                        Button(sheet.plan.isNoOp ? tr("install.nothing", "Nothing to Change") : tr("install.apply", "Apply Changes")) { model.confirmInstallSheet() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .disabled(sheet.plan.isNoOp)
                    }
                }
            }
            .padding(22)
            .frame(width: 720, height: 600)
        }
    }

    private func doneMessage(_ sheet: SettingsModel.InstallSheet) -> String {
        var message = tr("install.done", "Saved.")
        if let backup = sheet.backupLocation {
            message += " " + tr("install.backup", "Backup: %@", Formatting.shortPath(backup.path, components: 4) ?? backup.path)
        }
        switch sheet.target {
        case .claudeInstall: message += " " + tr("install.done.claude", "New and running Claude Code sessions pick up the hooks automatically.")
        case .codexHooksInstall: message += " " + tr("install.done.codex", "Now open Codex and run /hooks to trust them.")
        default: break
        }
        return message
    }
}

/// Changed lines with three lines of context, coloured.
struct DiffView: View {
    let lines: [String]

    var body: some View {
        let visible = condensed
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(PulseTypography.mono)
                        .foregroundStyle(line.hasPrefix("+") ? Theme.nativeGlass.tone(.success) : (line.hasPrefix("-") ? Theme.nativeGlass.tone(.failure) : .secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.hasPrefix("+") ? Theme.nativeGlass.tone(.success).opacity(0.08) : (line.hasPrefix("-") ? Theme.nativeGlass.tone(.failure).opacity(0.08) : .clear))
                }
            }
            .padding(10)
            .textSelection(.enabled)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var condensed: [String] {
        let changed = lines.indices.filter { lines[$0].hasPrefix("+") || lines[$0].hasPrefix("-") }
        guard !changed.isEmpty else { return [tr("install.noChanges", "  (no changes)")] }
        var keep = Set<Int>()
        for index in changed {
            for offset in -3...3 where lines.indices.contains(index + offset) { keep.insert(index + offset) }
        }
        var result: [String] = []
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index > previous + 1 { result.append("  …") }
            result.append(lines[index])
            previous = index
        }
        return result
    }
}

/// Managed Mode: start a Codex task from PulseDock.
struct ManagedTaskSheet: View {
    @Bindable var model: SettingsModel
    @State private var folder: URL?
    @State private var prompt = ""
    @State private var error: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("managed.title", "Start a Codex task")).font(.title2.weight(.semibold))
            Text(tr("managed.body", "PulseDock starts Codex's official app-server for this task. Approvals that Codex requests appear in the Agent Card, and nothing is approved without you."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(folder.map { Formatting.shortPath($0.path) ?? $0.path } ?? tr("managed.noFolder", "No project folder selected"))
                    .font(PulseTypography.mono)
                Spacer()
                Button(tr("managed.choose", "Choose Folder…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK { folder = panel.url }
                }
            }
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            if let error { Text(error).foregroundStyle(Theme.nativeGlass.tone(.failure)).font(.callout) }
            HStack {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("common.cancel", "Cancel")) { model.managedTaskSheetVisible = false }
                Button(tr("managed.start", "Start Task")) { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(folder == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running)
            }
        }
        .padding(22)
        .frame(width: 560, height: 400)
    }

    private var statusText: String {
        switch model.services.managedCodex.state {
        case .running: tr("managed.state.running", "App-server running")
        case .starting: tr("managed.state.starting", "Starting app-server…")
        case let .failed(message), let .unavailable(message): message
        case .stopped: ""
        }
    }

    private func start() {
        guard let folder else { return }
        running = true
        error = nil
        Task { @MainActor in
            do {
                try await model.services.managedCodex.startTask(projectPath: folder.path, prompt: prompt)
                model.managedTaskSheetVisible = false
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            running = false
        }
    }
}
