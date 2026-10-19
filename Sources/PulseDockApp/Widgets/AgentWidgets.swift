import AgentCore
import DockRendering
import Observation
import SwiftUI

/// Keeps the recent beats and test runs that feed Agent Heartbeat and Pulse Buddy. In memory
/// only (the event history itself is in SQLite, subject to the privacy settings).
@Observable
final class AgentActivityRecorder {
    private(set) var beats: [AgentHeartbeat.Beat] = []
    private(set) var testRuns: [AgentHeartbeat.TestRun] = []
    private(set) var revision = 0
    static let retention: TimeInterval = 2 * 3600

    func record(_ events: [AgentEvent]) {
        var changed = false
        for event in events {
            if let beat = AgentHeartbeat.beat(for: event) {
                beats.append(beat)
                changed = true
            }
            if let run = AgentHeartbeat.testRun(from: event), !testRuns.contains(where: { $0.id == run.id }) {
                testRuns.append(run)
                changed = true
            }
        }
        guard changed else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        beats.removeAll { $0.date < cutoff }
        if beats.count > 5000 { beats.removeFirst(beats.count - 5000) }
        if testRuns.count > 60 { testRuns.removeFirst(testRuns.count - 60) }
        revision += 1
    }

    func clearDemo() {
        beats.removeAll(where: \.isDemo)
        testRuns.removeAll(where: \.isDemo)
        revision += 1
    }
}

// MARK: - Agent Heartbeat

/// A flat line while agents are quiet; each observed event is a spike, coloured by what
/// happened (activity, completion, failure, a request for you). Up to three sessions.
struct HeartbeatTile: View {
    let recorder: AgentActivityRecorder
    let store: AgentStore
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            // The tile draws one trace for all sessions (the panel splits them by session).
            let combined = recorder.beats.map { AgentHeartbeat.Beat(session: Self.allSessions, date: $0.date, kind: $0.kind, isDemo: $0.isDemo) }
            let lanes = AgentHeartbeat.lanes(combined, now: context.date, window: 10 * 60, bucketCount: 24, maxLanes: 1)
            let lane = lanes.first
            VStack(alignment: .leading, spacing: 2) {
                ECGLine(counts: lane?.counts ?? Array(repeating: 0, count: 24), kinds: lane?.kinds ?? Array(repeating: nil, count: 24), theme: theme)
                    .opacity(lane == nil ? 0.45 : 1)
                    .frame(height: 24)
                HStack(spacing: 4) {
                    Circle().fill(theme.tone(statusTone)).frame(width: 5, height: 5)
                    Text(caption(lanes: lanes, now: context.date))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if lane?.isDemo == true || store.isDemoRunning { DemoBadge() }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("widget.agentHeartbeat", "Agent Heartbeat"))
            .accessibilityValue(caption(lanes: lanes, now: context.date))
        }
    }

    private static let allSessions = SessionKey(provider: .demo, sessionID: "all")

    private var statusTone: StatusTone {
        let summary = store.summary
        if summary.attentionCount > 0 { return .attention }
        if summary.workingCount > 0 { return .working }
        return summary.liveCount > 0 ? .idle : .offline
    }

    private func caption(lanes: [AgentHeartbeat.Lane], now: Date) -> String {
        if store.summary.attentionCount > 0 { return tr("heartbeat.caption.attention", "Waiting for you") }
        let bpm = AgentHeartbeat.beatsPerMinute(recorder.beats, now: now, window: 5 * 60)
        if bpm > 0 { return trp("heartbeat.caption.perMinute", one: "%ld event/min", other: "%ld events/min", bpm) }
        if store.summary.workingCount > 0 { return tr("heartbeat.caption.working", "Working") }
        return lanes.isEmpty ? tr("heartbeat.caption.flat", "Quiet") : tr("heartbeat.caption.calm", "Calm")
    }
}

/// One ECG trace. The shape is deterministic: a spike per bucket with events, its height
/// growing with the number of events, so the same data always draws the same line.
struct ECGLine: View {
    let counts: [Int]
    let kinds: [AgentHeartbeat.BeatKind?]
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            guard counts.count > 1 else { return }
            let step = size.width / Double(counts.count)
            let mid = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 0, y: mid))
            for (index, count) in counts.enumerated() {
                let x = Double(index) * step
                if count == 0 {
                    path.addLine(to: CGPoint(x: x + step, y: mid))
                    continue
                }
                let amplitude = min(mid - 1, 4 + Double(min(count, 6)) * 1.8)
                path.addLine(to: CGPoint(x: x + step * 0.2, y: mid))
                path.addLine(to: CGPoint(x: x + step * 0.35, y: mid + amplitude * 0.35))
                path.addLine(to: CGPoint(x: x + step * 0.5, y: mid - amplitude))
                path.addLine(to: CGPoint(x: x + step * 0.65, y: mid + amplitude * 0.55))
                path.addLine(to: CGPoint(x: x + step * 0.8, y: mid))
                path.addLine(to: CGPoint(x: x + step, y: mid))
            }
            let colors = gradientStops(width: size.width, step: step)
            context.stroke(path, with: .linearGradient(Gradient(stops: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    private func gradientStops(width: Double, step: Double) -> [Gradient.Stop] {
        guard width > 0 else { return [.init(color: theme.tone(.idle), location: 0)] }
        var stops: [Gradient.Stop] = []
        for (index, kind) in kinds.enumerated() {
            let location = min(1, (Double(index) + 0.5) * step / width)
            stops.append(.init(color: color(kind), location: location))
        }
        return stops.isEmpty ? [.init(color: theme.tone(.idle), location: 0)] : stops
    }

    private func color(_ kind: AgentHeartbeat.BeatKind?) -> Color {
        switch kind {
        case .attention?: theme.tone(.attention)
        case .failure?: theme.tone(.failure)
        case .completion?: theme.tone(.success)
        case .activity?: theme.tone(.working)
        case nil: theme.tone(.idle).opacity(0.7)
        }
    }
}

struct HeartbeatPanel: View {
    let recorder: AgentActivityRecorder
    let store: AgentStore
    let theme: Theme
    let accessibility: AccessibilityOptions
    let openSession: (SessionKey) -> Void

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.agentHeartbeat", "Agent Heartbeat")) {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                let lanes = AgentHeartbeat.lanes(recorder.beats, now: context.date, window: 30 * 60, bucketCount: 48, maxLanes: 4)
                VStack(alignment: .leading, spacing: 12) {
                    if lanes.isEmpty {
                        Text(tr("heartbeat.empty", "No agent activity in the last 30 minutes. Each spike is a real event: a tool call, an end of turn, a failure or a request for you."))
                            .font(PulseTypography.panelBody)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(lanes) { lane in
                        Button { openSession(lane.session) } label: { laneRow(lane) }
                            .buttonStyle(.plain)
                    }
                    if !lanes.isEmpty { legend }
                    Divider().opacity(0.4)
                    testRadar(now: context.date)
                }
            }
        }
    }

    private func laneRow(_ lane: AgentHeartbeat.Lane) -> some View {
        let presentation = store.presentation(for: lane.session)
        let text = store.text
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: AgentText.symbol(presentation?.state ?? .unknown))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.tone(AgentText.tone(presentation?.state ?? .unknown)))
                Text(presentation.map { text.project(store.project(for: $0.session)) } ?? lane.session.provider.displayName)
                    .font(PulseTypography.panelHeadline)
                    .lineLimit(1)
                if lane.isDemo { DemoBadge() }
                Spacer()
                Text(trp("heartbeat.events", one: "%ld event", other: "%ld events", lane.total))
                    .font(PulseTypography.panelCaption)
                    .foregroundStyle(.secondary)
            }
            ECGLine(counts: lane.counts, kinds: lane.kinds, theme: theme)
                .frame(height: 22)
        }
        .contentShape(Rectangle())
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(.working, tr("heartbeat.legend.activity", "Activity"))
            legendItem(.success, tr("heartbeat.legend.turn", "End of turn"))
            legendItem(.failure, tr("heartbeat.legend.failure", "Failure"))
            legendItem(.attention, tr("heartbeat.legend.attention", "Needs you"))
        }
        .font(PulseTypography.panelCaption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ tone: StatusTone, _ label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(theme.tone(tone)).frame(width: 10, height: 3)
            Text(label)
        }
    }

    private func testRadar(now: Date) -> some View {
        let runs = AgentHeartbeat.latestRuns(recorder.testRuns)
        return VStack(alignment: .leading, spacing: 8) {
            Label(tr("heartbeat.testRadar", "Test Radar"), systemImage: "checkmark.shield")
                .font(PulseTypography.panelHeadline)
            if runs.isEmpty {
                Text(tr("heartbeat.testRadar.empty", "When an agent runs your tests (swift test, npm test, pytest…), the latest result per project appears here."))
                    .font(PulseTypography.panelCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(runs) { run in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(run.outcome))
                        .foregroundStyle(theme.tone(tone(run.outcome)))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(projectName(run)).font(PulseTypography.panelBody).lineLimit(1)
                            if run.isDemo { DemoBadge() }
                        }
                        Text(outcomeText(run.outcome))
                            .font(PulseTypography.panelCaption)
                            .foregroundStyle(theme.tone(tone(run.outcome)))
                        if !store.text.privacyMode, let command = run.command {
                            Text(command).font(PulseTypography.mono).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Text(Formatting.relative(run.date, now: now))
                        .font(PulseTypography.panelCaption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func projectName(_ run: AgentHeartbeat.TestRun) -> String {
        if let session = store.presentation(for: run.session)?.session {
            return store.text.project(store.project(for: session))
        }
        guard !store.text.privacyMode else { return tr("agent.privacy.project", "Project") }
        return run.projectPath.map { ($0 as NSString).lastPathComponent } ?? run.session.provider.displayName
    }

    private func symbol(_ outcome: AgentHeartbeat.TestRun.Outcome) -> String {
        switch outcome {
        case .passed: "checkmark.circle.fill"
        case .finishedWithoutError: "checkmark.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func tone(_ outcome: AgentHeartbeat.TestRun.Outcome) -> StatusTone {
        switch outcome {
        case .passed, .finishedWithoutError: .success
        case .failed: .failure
        }
    }

    private func outcomeText(_ outcome: AgentHeartbeat.TestRun.Outcome) -> String {
        switch outcome {
        case .passed: tr("heartbeat.test.passed", "Tests passed (exit 0)")
        case .finishedWithoutError: tr("heartbeat.test.finished", "Test command finished without error")
        case let .failed(code?): tr("heartbeat.test.failedCode", "Tests failed (exit %ld)", code)
        case .failed(nil): tr("heartbeat.test.failed", "Test command failed")
        }
    }
}

// MARK: - Pulse Buddy

/// A small original companion whose mood is the agents' aggregate state. It hops when the
/// mood changes and, while an agent waits for you, every few seconds; it stays still with
/// Reduce Motion.
enum BuddyMood: Equatable {
    case sleeping, idle, working, attention, failure, celebrating, offline

    var tone: StatusTone {
        switch self {
        case .sleeping, .idle: .idle
        case .working: .working
        case .attention: .attention
        case .failure: .failure
        case .celebrating: .success
        case .offline: .offline
        }
    }

}

extension AggregateSummary {
    var buddyMood: BuddyMood {
        if attentionCount > 0 { return .attention }
        if (counts[.failure] ?? 0) > 0 { return .failure }
        if workingCount > 0 { return .working }
        if (counts[.recentCompletion] ?? 0) > 0 { return .celebrating }
        if liveCount > 0 { return .idle }
        return .sleeping
    }
}

struct PulseBuddyView: View {
    let mood: BuddyMood
    let theme: Theme
    let reduceMotion: Bool
    var size: Double = 40

    /// What makes the buddy hop: a change of mood, and every few seconds while an agent waits
    /// for the user. Between hops nothing is rendered: no per-frame animation, so a working
    /// agent costs no CPU here (a continuous bob used to cost ~15 % CPU).
    private struct HopTrigger: Equatable {
        var mood: BuddyMood
        var tick: Int
    }

    private struct Hop {
        var lift = 0.0
        var stretch = 1.0
    }

    var body: some View {
        let interval: TimeInterval = mood == .attention && !reduceMotion ? 4 : 3600
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let tick = mood == .attention ? Int(context.date.timeIntervalSinceReferenceDate / 4) : 0
            if reduceMotion {
                creature
            } else {
                creature
                    .keyframeAnimator(initialValue: Hop(), trigger: HopTrigger(mood: mood, tick: tick)) { content, hop in
                        content
                            .scaleEffect(x: 2 - hop.stretch, y: hop.stretch, anchor: .bottom)
                            .offset(y: -hop.lift)
                    } keyframes: { _ in
                        KeyframeTrack(\.lift) {
                            CubicKeyframe(0, duration: 0.08)
                            SpringKeyframe(size * 0.12, duration: 0.18, spring: .snappy)
                            SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                        }
                        KeyframeTrack(\.stretch) {
                            CubicKeyframe(0.9, duration: 0.08)
                            CubicKeyframe(1.07, duration: 0.16)
                            SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                        }
                    }
            }
        }
    }

    private var creature: some View {
        let color = theme.tone(mood.tone)
        return ZStack {
            // Soft shadow on the "floor".
            Ellipse()
                .fill(Color.black.opacity(0.16))
                .frame(width: size * 0.62, height: size * 0.1)
                .offset(y: size * 0.44)
            ZStack {
                BuddyShape()
                    .fill(color)
                BuddyShape()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.38), .clear, Color.black.opacity(0.22)], startPoint: .top, endPoint: .bottom))
                // A soft highlight on the "forehead".
                Ellipse()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: size * 0.2, height: size * 0.09)
                    .offset(x: -size * 0.14, y: -size * 0.2)
                BuddyShape()
                    .stroke(Color.white.opacity(0.4), lineWidth: 0.8)
                face
            }
            .frame(width: size * 0.78, height: size * 0.72)
            accessory
                .offset(x: size * 0.3, y: -size * 0.32)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var face: some View {
        let eye = size * 0.1
        HStack(spacing: size * 0.16) {
            ForEach(0..<2, id: \.self) { _ in
                switch mood {
                case .sleeping:
                    Capsule().fill(Color.white).frame(width: eye * 1.4, height: eye * 0.32)
                case .celebrating:
                    Image(systemName: "chevron.up").font(.system(size: eye * 1.4, weight: .heavy)).foregroundStyle(.white)
                case .failure:
                    Image(systemName: "chevron.down").font(.system(size: eye * 1.3, weight: .heavy)).foregroundStyle(.white)
                case .attention:
                    Circle().fill(Color.white).frame(width: eye * 1.35, height: eye * 1.35)
                        .overlay(Circle().fill(Color.black.opacity(0.75)).frame(width: eye * 0.6, height: eye * 0.6))
                case .working:
                    // Looking down at the work.
                    Capsule().fill(Color.white).frame(width: eye, height: eye * 1.1).offset(y: eye * 0.35)
                default:
                    Capsule().fill(Color.white).frame(width: eye, height: eye * 1.25)
                }
            }
        }
        .overlay(alignment: .bottom) { mouth.offset(y: size * 0.11) }
        .offset(y: -size * 0.03)
    }

    @ViewBuilder private var mouth: some View {
        let width = size * 0.16
        switch mood {
        case .attention:
            Ellipse().fill(Color.black.opacity(0.55)).frame(width: width * 0.45, height: width * 0.5)
        case .failure:
            Capsule().fill(Color.white.opacity(0.85)).frame(width: width * 0.7, height: max(1.2, size * 0.022))
        case .sleeping, .offline:
            EmptyView()
        default:
            SmileShape().stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: max(1.2, size * 0.028), lineCap: .round))
                .frame(width: width, height: width * (mood == .celebrating ? 0.5 : 0.32))
        }
    }

    @ViewBuilder private var accessory: some View {
        let font = Font.system(size: size * 0.26, weight: .bold, design: .rounded)
        switch mood {
        case .sleeping: Text("z").font(font).foregroundStyle(.secondary)
        case .attention:
            Text("!")
                .font(.system(size: size * 0.22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size * 0.3, height: size * 0.3)
                .background(Circle().fill(theme.tone(.attention)))
                .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
        case .celebrating: Image(systemName: "sparkle").font(font).foregroundStyle(theme.tone(.success))
        case .failure: Image(systemName: "drop.fill").font(.system(size: size * 0.16)).foregroundStyle(theme.tone(.working).opacity(0.8))
        case .working: Image(systemName: "ellipsis.bubble.fill").font(.system(size: size * 0.2)).foregroundStyle(.white, theme.tone(.working))
        default: EmptyView()
        }
    }
}

/// A rounded, slightly pear-shaped body (original design).
nonisolated struct BuddyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.62),
                      control1: CGPoint(x: rect.minX + w * 0.86, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.3))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.9),
                      control2: CGPoint(x: rect.minX + w * 0.8, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.62),
                      control1: CGPoint(x: rect.minX + w * 0.2, y: rect.maxY),
                      control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.9))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.3),
                      control2: CGPoint(x: rect.minX + w * 0.14, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct PulseBuddyTile: View {
    let store: AgentStore
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        let mood = store.summary.buddyMood
        PulseBuddyView(mood: mood, theme: theme, reduceMotion: accessibility.reduceMotion, size: 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                // The mood includes simulated sessions while Demo mode runs.
                if store.isDemoRunning { DemoBadge().scaleEffect(0.85) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("widget.pulseBuddy", "Pulse Buddy"))
            .accessibilityValue(BuddyText.mood(mood))
    }
}

enum BuddyText {
    static func mood(_ mood: BuddyMood) -> String {
        switch mood {
        case .sleeping: tr("buddy.sleeping", "Sleeping — no agent sessions")
        case .idle: tr("buddy.idle", "Relaxed — sessions are open, nothing running")
        case .working: tr("buddy.working", "Busy — an agent is working")
        case .attention: tr("buddy.attention", "Alert — an agent is waiting for you")
        case .failure: tr("buddy.failure", "Worried — something failed recently")
        case .celebrating: tr("buddy.celebrating", "Happy — a turn just finished")
        case .offline: tr("buddy.offline", "Offline")
        }
    }
}

struct PulseBuddyPanel: View {
    let store: AgentStore
    let recorder: AgentActivityRecorder
    let theme: Theme
    let accessibility: AccessibilityOptions

    var body: some View {
        let summary = store.summary
        let mood = summary.buddyMood
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.pulseBuddy", "Pulse Buddy")) {
            HStack(spacing: 14) {
                PulseBuddyView(mood: mood, theme: theme, reduceMotion: accessibility.reduceMotion, size: 78)
                VStack(alignment: .leading, spacing: 4) {
                    if store.isDemoRunning { DemoBadge() }
                    Text(BuddyText.mood(mood)).font(PulseTypography.panelHeadline).fixedSize(horizontal: false, vertical: true)
                    if let primary = summary.primary {
                        Text(store.text.headline(for: primary))
                            .font(PulseTypography.panelBody)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            let hour = recorder.beats.filter { $0.date > Date().addingTimeInterval(-3600) }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    stat(hour.filter { $0.kind == .activity }.count, tr("buddy.stat.activity", "events"))
                    stat(hour.filter { $0.kind == .completion }.count, tr("buddy.stat.turns", "turns finished"))
                }
                GridRow {
                    stat(hour.filter { $0.kind == .attention }.count, tr("buddy.stat.attention", "requests for you"))
                    stat(hour.filter { $0.kind == .failure }.count, tr("buddy.stat.failures", "failures"))
                }
            }
            Text(tr("buddy.footer", "Last hour, from real agent events. Pulse Buddy hops when something changes and while an agent waits for you."))
                .font(PulseTypography.panelCaption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value, format: .number).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(PulseTypography.panelCaption).foregroundStyle(.secondary)
        }
    }
}

nonisolated struct SmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        return path
    }
}
