import AgentCore
import AppKit
import DockCore
import DockRendering
import SwiftUI

/// First-run tour: what PulseDock is, how it coexists with the macOS Dock, and (optionally)
/// connecting agents. Nothing outside PulseDock changes without an explicit choice.
struct OnboardingView: View {
    let services: AppServices
    let finish: () -> Void
    @State private var step = 0

    var body: some View {
        let theme = Theme.aurora
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(.sRGB, red: 0.13, green: 0.15, blue: 0.33), Color(.sRGB, red: 0.05, green: 0.05, blue: 0.10)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 14) {
                    if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 92, height: 92)
                    }
                    Text("PulseDock").font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    Text(tr("onboarding.tagline", "Your Mac. Your apps. Your AI agents. One living Dock."))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.top, 20)
            }
            .frame(height: 230)

            Group {
                switch step {
                case 0: welcome
                case 1: mode
                default: agents
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle().fill(index == step ? theme.tone(.working) : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 {
                    Button(tr("onboarding.back", "Back")) { withAnimation { step -= 1 } }
                }
                Button(step == 2 ? tr("onboarding.start", "Start Using PulseDock") : tr("onboarding.continue", "Continue")) {
                    if step == 2 { finish() } else { withAnimation { step += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
        .frame(width: 620, height: 560)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            feature("dock.rectangle", tr("onboarding.f1.title", "A dock made for the way you work"),
                    tr("onboarding.f1.body", "Your apps, imported from the macOS Dock, with organic magnification, workspaces and widgets."))
            feature("waveform.path.ecg", tr("onboarding.f2.title", "Agent Pulse"),
                    tr("onboarding.f2.body", "See what Claude Code and Codex are doing, notice at once when one needs you, and jump back to the right session."))
            feature("hand.raised", tr("onboarding.f3.title", "Private by design"),
                    tr("onboarding.f3.body", "Everything stays on this Mac. Prompts, code and command output are never recorded."))
        }
    }

    private var mode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("onboarding.mode.title", "PulseDock starts alongside the macOS Dock")).font(.title3.weight(.semibold))
            Text(tr("onboarding.mode.body", "In Companion Mode nothing in your system changes: PulseDock floats above the macOS Dock. When you are ready, Settings › General › Replacement Mode sets the macOS Dock to auto-hide — and restores it whenever you want."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let imported = services.settings.settings.workspaces.first { $0.preset == .personal }?.pinned.count ?? 0
            Label(trp("onboarding.mode.importedPersonal", one: "%ld app from your macOS Dock is in the Personal workspace; Development has your terminal, editor and Claude.", other: "%ld apps from your macOS Dock are in the Personal workspace; Development has your terminal, editor and Claude.", imported), systemImage: "square.and.arrow.down")
            Label(tr("onboarding.mode.tips", "Right-click the dock for workspaces, themes and widgets. Drag icons to reorder; drag one out to remove it."), systemImage: "cursorarrow.click.2")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("onboarding.agents.title", "Connect your agents (optional)")).font(.title3.weight(.semibold))
            Text(tr("onboarding.agents.body", "PulseDock uses the official hooks of each agent. You will see the exact change before anything is written, with a backup and one-click removal."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                agentButton(.claudeCode, found: services.integrations.claude?.isInstalled == true)
                agentButton(.codex, found: services.integrations.codex?.isInstalled == true)
            }
            Button(tr("onboarding.agents.demo", "Try the Demo first")) {
                services.settings.update { $0.advanced.demoMode = true }
            }
            .buttonStyle(.link)
            Text(tr("onboarding.agents.privacy", "Privacy Mode (%@) hides project names whenever you share your screen.", HotKeys.Action.togglePrivacy.displayShortcut))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func agentButton(_ provider: AgentProvider, found: Bool) -> some View {
        Button {
            services.settings.update { $0.hasCompletedOnboarding = true }
            services.openSettings(pane: .agents)
        } label: {
            HStack(spacing: 10) {
                AgentGlyph(provider: provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.headline)
                    Text(found ? tr("onboarding.agents.found", "Found — set up…") : tr("onboarding.agents.notFound", "Not found on this Mac"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(width: 230, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .disabled(!found)
    }

    private func feature(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 30).foregroundStyle(Theme.aurora.tone(.working))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
