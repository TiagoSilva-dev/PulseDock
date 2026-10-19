import AgentCore
import AppKit
import DockRendering
import SwiftUI

/// Small summary shown when the pointer rests on the island (no click needed).
struct QuickPeekView: View {
    let store: AgentStore
    let settings: SettingsStore
    let accessibility: AccessibilityOptions

    var body: some View {
        let theme = Theme.theme(for: settings.settings.effectiveTheme)
        let sessions = Array(store.summary.sessions.prefix(4))
        VStack(alignment: .leading, spacing: 7) {
            if sessions.isEmpty {
                Text(tr("peek.empty", "No active agent sessions"))
                    .font(PulseTypography.panelBody)
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions) { presentation in
                HStack(spacing: 8) {
                    AgentGlyph(provider: presentation.session.provider, size: 16)
                    Text(store.text.project(store.project(for: presentation.session)))
                        .font(PulseTypography.panelHeadline)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: AgentText.symbol(presentation.state))
                        .foregroundStyle(theme.tone(AgentText.tone(presentation.state)))
                        .font(.system(size: 10, weight: .semibold))
                    Text(store.text.headline(for: presentation))
                        .font(PulseTypography.panelCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if store.summary.sessions.count > sessions.count {
                Text(tr("peek.more", "+%ld more", store.summary.sessions.count - sessions.count))
                    .font(PulseTypography.panelCaption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background {
            PulseGlassSurface(theme: theme, cornerRadius: 16, accessibility: accessibility, legibility: .content)
        }
        .environment(\.colorScheme, theme.forcedColorScheme ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
        .accessibilityElement(children: .combine)
    }
}

/// Presents the Agent Card and Quick Peek above the island and performs card actions.
final class AgentUIController {
    private let store: AgentStore
    private let settings: SettingsStore
    private let integrations: IntegrationsManager
    private let managed: CodexManagedService
    private let accessibility: AccessibilityOptions
    private weak var dockWindow: DockWindowController?
    private var cardPanel: AnchoredPanel?
    private var peekPanel: AnchoredPanel?
    private var peekTask: Task<Void, Never>?
    private var lastAnchor: CGRect = .zero
    var openMissionControl: (SessionKey?) -> Void = { _ in }
    var openAgentSettings: () -> Void = {}

    init(store: AgentStore, settings: SettingsStore, integrations: IntegrationsManager, managed: CodexManagedService,
         accessibility: AccessibilityOptions, dockWindow: DockWindowController) {
        self.store = store
        self.settings = settings
        self.integrations = integrations
        self.managed = managed
        self.accessibility = accessibility
        self.dockWindow = dockWindow
    }

    var isCardVisible: Bool { cardPanel?.isVisible == true }

    // MARK: Card

    func toggleCard(anchor: CGRect) {
        if isCardVisible {
            closeCard()
        } else {
            showCard(anchor: anchor)
        }
    }

    func showCard(anchor: CGRect) {
        hidePeek()
        lastAnchor = anchor
        let panel = cardPanel ?? AnchoredPanel(allowsKey: true)
        panel.onClose = { [weak self] in
            self?.dockWindow?.isPresentingAuxiliaryUI = false
        }
        cardPanel = panel
        let view = AgentCardView(store: store, integrations: integrations, managed: managed, settings: settings,
                                 accessibility: accessibility, actions: actions)
        dockWindow?.isPresentingAuxiliaryUI = true
        panel.present(view, size: cardSize(), above: anchor, gap: 12)
        Task { await integrations.refresh() }
    }

    func closeCard() {
        cardPanel?.dismiss()
    }

    /// Keeps the card's height in step with its content.
    func summaryChanged() {
        guard let cardPanel, cardPanel.isVisible else { return }
        cardPanel.resize(to: cardSize(), above: lastAnchor, gap: 12)
    }

    private func cardSize() -> CGSize {
        let count = store.summary.sessions.count
        let attention = store.summary.sessions.filter { $0.category == .attention }.count
        let base: Double = 64 + 40
        let rows = count == 0 ? 210 : Double(count) * 86 + Double(attention) * 74 + 20
        return CGSize(width: 392, height: min(560, base + rows))
    }

    private var actions: AgentCardActions {
        AgentCardActions(
            openSession: { [weak self] key in self?.openSession(key) },
            revealProject: { [weak self] key in self?.revealProject(key) },
            copyPath: { [weak self] key in self?.copyPath(key) },
            showEvents: { [weak self] key in
                self?.closeCard()
                self?.openMissionControl(key)
            },
            openMissionControl: { [weak self] in
                self?.closeCard()
                self?.openMissionControl(nil)
            },
            openAgentSettings: { [weak self] in
                self?.closeCard()
                self?.openAgentSettings()
            },
            startDemo: { [weak self] in
                self?.settings.update { $0.advanced.demoMode = true }
            },
            respond: { [weak self] key, request, decision in self?.respond(key, request: request, decision: decision) },
            togglePrivacy: { [weak self] in self?.settings.update { $0.privacy.privacyMode.toggle() } }
        )
    }

    func openSession(_ key: SessionKey) {
        guard let session = store.engine.session(key) else { return }
        closeCard()
        if session.isDemo { return }
        SmartReturn.returnTo(session, project: store.project(for: session)) { _ in }
    }

    private func revealProject(_ key: SessionKey) {
        guard let session = store.engine.session(key), let path = store.project(for: session)?.rootPath ?? session.projectPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyPath(_ key: SessionKey) {
        guard let session = store.engine.session(key), let path = store.project(for: session)?.rootPath ?? session.projectPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func respond(_ key: SessionKey, request: AttentionRequest, decision: String) {
        guard let session = store.engine.session(key) else { return }
        do {
            try managed.respond(to: request, in: session, decision: decision)
        } catch {
            let alert = NSAlert()
            alert.messageText = tr("approval.failed", "The decision could not be sent")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: Quick Peek

    func islandHover(_ hovering: Bool, anchor: CGRect) {
        peekTask?.cancel()
        guard hovering, !isCardVisible else {
            peekTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.hidePeek()
            }
            return
        }
        let delay = settings.settings.agents.quickPeekDelay
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.isCardVisible else { return }
            self.showPeek(anchor: anchor)
        }
    }

    private func showPeek(anchor: CGRect) {
        let panel = peekPanel ?? AnchoredPanel(allowsKey: false)
        peekPanel = panel
        let count = min(4, store.summary.sessions.count)
        let height = Double(max(1, count)) * 24 + 24 + (store.summary.sessions.count > 4 ? 18 : 0)
        panel.present(QuickPeekView(store: store, settings: settings, accessibility: accessibility),
                      size: CGSize(width: 300, height: height), above: anchor, gap: 12)
    }

    func hidePeek() {
        peekPanel?.dismiss()
    }

    // MARK: Island menu

    func buildIslandMenu(_ menu: NSMenu) {
        menu.add(tr("island.menu.open", "Show AI Activity"), symbol: "sparkles") { [weak self] in
            guard let self, let frame = self.dockWindow?.screenFrame(ofEntry: "agentPulse") else { return }
            self.showCard(anchor: frame)
        }
        menu.add(tr("island.menu.missionControl", "AI Mission Control"), symbol: "rectangle.3.group") { [weak self] in
            self?.openMissionControl(nil)
        }
        menu.addSeparator()
        let privacy = settings.settings.privacy.privacyMode
        menu.add(tr("island.menu.privacy", "Privacy Mode"), symbol: "eye.slash", state: privacy ? .on : .off) { [weak self] in
            self?.settings.update { $0.privacy.privacyMode.toggle() }
        }
        menu.add(tr("island.menu.demo", "Demo Mode"), symbol: "theatermasks", state: settings.settings.advanced.demoMode ? .on : .off) { [weak self] in
            self?.settings.update { $0.advanced.demoMode.toggle() }
        }
        menu.addSeparator()
        menu.add(tr("island.menu.settings", "Agent Settings…"), symbol: "gearshape") { [weak self] in self?.openAgentSettings() }
    }
}
