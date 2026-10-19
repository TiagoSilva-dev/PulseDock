import AgentCore
import DockRendering
import SwiftUI

/// Claude Usage tile: the 5-hour and weekly limits as two rings (Pro and Max). Without limits
/// it shows today's cost estimate; before connecting, a call to action.
struct ClaudeUsageTile: View {
    let usage: ClaudeUsageService
    let theme: Theme

    var body: some View {
        // Resets and staleness are minute-level facts: one evaluation per minute at most.
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if let limits = usage.limits(now: now) {
            HStack(spacing: 6) {
                if let window = limits.fiveHour { UsageRing(percent: window.usedPercent, label: "5h", theme: theme) }
                if let window = limits.sevenDay { UsageRing(percent: window.usedPercent, label: "7d", theme: theme) }
                if limits.fiveHour == nil || limits.sevenDay == nil, let spend = limits.spend {
                    UsageRing(percent: spend.usedPercent, label: "$", theme: theme)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("widget.claudeUsage", "Claude Usage"))
            .accessibilityValue(ClaudeUsageText.accessibilitySummary(limits))
        } else {
            VStack(spacing: 3) {
                AgentGlyph(provider: .claudeCode, size: 20)
                Text(fallbackText(now: now))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func fallbackText(now: Date) -> String {
        if usage.lastUpdate == nil {
            return usage.isConnected ? tr("usage.tile.waiting", "Waiting") : tr("usage.tile.connect", "Connect")
        }
        return Formatting.usd(usage.ledger.day(now).costUSD)
    }
}

struct UsageRing: View {
    let percent: Double
    let label: String
    let theme: Theme

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, percent / 100)))
                    .stroke(theme.tone(ClaudeUsageText.tone(percent)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 27, height: 27)
            Text(label)
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

enum ClaudeUsageText {
    /// Tone thresholds match the notifications: amber from 80%, red from 95%.
    static func tone(_ percent: Double) -> StatusTone {
        percent >= 95 ? .failure : (percent >= 80 ? .attention : .working)
    }

    static func accessibilitySummary(_ limits: UsageLimits) -> String {
        var parts: [String] = []
        if let window = limits.fiveHour { parts.append(tr("usage.a11y.fiveHour", "5-hour limit %@", Formatting.percent(window.usedPercent / 100))) }
        if let window = limits.sevenDay { parts.append(tr("usage.a11y.sevenDay", "weekly limit %@", Formatting.percent(window.usedPercent / 100))) }
        if let spend = limits.spend { parts.append(tr("usage.a11y.spend", "spend limit %@", Formatting.percent(spend.usedPercent / 100))) }
        return parts.joined(separator: ", ")
    }
}

struct ClaudeUsagePanel: View {
    let usage: ClaudeUsageService
    let settings: SettingsStore
    let theme: Theme
    let accessibility: AccessibilityOptions
    let connect: () -> Void

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.claudeUsage", "Claude Usage")) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 14) { sections(now: context.date) }
            }
        }
    }

    @ViewBuilder private func sections(now: Date) -> some View {
        if usage.lastUpdate == nil {
            setup
        } else {
            limitsSection(now: now)
            todaySection(now: now)
            sessionsSection(now: now)
            footer(now: now)
        }
    }

    @ViewBuilder private var setup: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentGlyph(provider: .claudeCode, size: 30)
            Text(usage.isConnected
                 ? tr("usage.waiting", "Connected. The numbers arrive with Claude Code's next reply in any session.")
                 : tr("usage.intro", "See your 5-hour and weekly Claude limits, when they reset and today's cost estimate. PulseDock reads them from Claude Code's official status line — no credentials."))
                .font(PulseTypography.panelBody)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !usage.isConnected {
            PillButton(title: tr("usage.connect", "Connect to Claude Code…"), symbol: "link", prominent: true, tint: theme.tone(.working), action: connect)
            Text(tr("usage.connectHelp", "You review the exact change to ~/.claude/settings.json first. A status line you already have keeps working."))
                .font(PulseTypography.panelCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func limitsSection(now: Date) -> some View {
        if let limits = usage.limits(now: now) {
            if let window = limits.fiveHour {
                LimitRow(title: tr("usage.fiveHour", "5-hour session"), percent: window.usedPercent,
                         detail: tr("usage.resets", "Resets %@", Formatting.reset(window.resetsAt, now: now)), theme: theme)
                if let eta = usage.ledger.fiveHourExhaustion(now: now) {
                    Label(tr("usage.projection", "At this pace you reach the limit around %@.", Formatting.timeFormatter.string(from: eta)), systemImage: "speedometer")
                        .font(PulseTypography.panelCaption)
                        .foregroundStyle(theme.tone(.attention))
                }
            }
            if let window = limits.sevenDay {
                LimitRow(title: tr("usage.sevenDay", "Weekly"), percent: window.usedPercent,
                         detail: tr("usage.resets", "Resets %@", Formatting.reset(window.resetsAt, now: now)), theme: theme)
            }
            if let spend = limits.spend {
                LimitRow(title: tr("usage.spend", "Spend limit"), percent: spend.usedPercent, detail: spendDetail(spend, now: now), theme: theme)
            }
        } else {
            Label(tr("usage.noLimits", "Limits appear for Claude Pro and Max plans after Claude Code's next reply."), systemImage: "info.circle")
                .font(PulseTypography.panelCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func spendDetail(_ spend: SpendWindow, now: Date) -> String {
        var parts: [String] = []
        if let used = spend.usedUSD, let limit = spend.limitUSD {
            parts.append(tr("usage.spendAmount", "%@ of %@", Formatting.usd(used), Formatting.usd(limit)))
        }
        if let reset = spend.resetsAt { parts.append(tr("usage.resets", "Resets %@", Formatting.reset(reset, now: now))) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func todaySection(now: Date) -> some View {
        let day = usage.ledger.day(now)
        PanelSection(title: tr("usage.today", "Today")) {
            HStack(spacing: 0) {
                stat(label: tr("usage.cost", "Cost estimate"), value: Formatting.usd(day.costUSD))
                stat(label: tr("usage.lines", "Lines"), value: "+\(day.linesAdded) −\(day.linesRemoved)")
                stat(label: tr("usage.sessions", "Sessions"), value: "\(day.sessionIDs.count)")
            }
            Text(day.partial
                 ? tr("usage.costNotePartial", "Claude Code's estimate at API list prices, not a bill. Sessions already open count from when PulseDock first saw them.")
                 : tr("usage.costNote", "Claude Code's estimate at API list prices, not a bill."))
                .font(PulseTypography.panelCaption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(PulseTypography.panelHeadline).monospacedDigit()
            Text(label).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func sessionsSection(now: Date) -> some View {
        let sessions = Array(usage.ledger.recentSessions(now: now).prefix(4))
        if !sessions.isEmpty {
            PanelSection(title: tr("usage.recentSessions", "Sessions")) {
                VStack(spacing: 8) {
                    ForEach(sessions, id: \.sessionID) { session in sessionRow(session, now: now) }
                }
            }
        }
    }

    private func sessionRow(_ session: ClaudeUsageSnapshot, now: Date) -> some View {
        let privacy = settings.settings.privacy.privacyMode
        let project = privacy ? tr("agent.privacy.project", "Project") : (session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? tr("agent.privacy.project", "Project"))
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(project).font(PulseTypography.panelBody).lineLimit(1)
                Text([session.modelName, Formatting.relative(session.observedAt, now: now)].compactMap { $0 }.joined(separator: " · "))
                    .font(PulseTypography.panelCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let context = session.contextUsedPercent {
                VStack(alignment: .trailing, spacing: 2) {
                    UsageBar(fraction: context / 100, tone: context >= 80 ? .attention : .idle, theme: theme).frame(width: 54)
                    Text(tr("usage.context", "Context %@", Formatting.percent(context / 100))).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
                }
            }
            if let cost = session.costUSD {
                Text(Formatting.usd(cost)).font(PulseTypography.panelCaption).monospacedDigit().frame(minWidth: 52, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func footer(now: Date) -> some View {
        if let last = usage.lastUpdate {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("usage.updated", "Updated %@ · Claude Code status line", Formatting.relative(last, now: now)))
                if now.timeIntervalSince(last) > 20 * 60 {
                    Text(tr("usage.staleNote", "Numbers update when Claude Code replies; usage elsewhere (claude.ai, other Macs) shows up then."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(PulseTypography.panelCaption)
            .foregroundStyle(.tertiary)
        }
    }
}

private struct LimitRow: View {
    let title: String
    let percent: Double
    let detail: String
    let theme: Theme

    var body: some View {
        let tone = ClaudeUsageText.tone(percent)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(PulseTypography.panelHeadline)
                if tone != .working {
                    Image(systemName: tone == .failure ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(theme.tone(tone))
                }
                Spacer()
                Text(Formatting.percent(percent / 100))
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tone == .working ? Color.primary : theme.tone(tone))
            }
            UsageBar(fraction: percent / 100, tone: tone, theme: theme)
            Text(detail).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UsageBar: View {
    let fraction: Double
    let tone: StatusTone
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(theme.tone(tone)).frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}
