import AppKit
import DockRendering
import SwiftUI

/// A progress ring with content in the middle (timers, Pomodoro, water, time progress).
struct WidgetRing<Center: View>: View {
    let progress: Double
    let color: Color
    var lineWidth: Double = 3.2
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(lineWidth / 2)
    }
}

/// A square tile: an SF Symbol with an optional caption and badge.
struct SymbolTile: View {
    let symbol: String
    let theme: Theme
    var tint: Color?
    var caption: String?
    var badge: Int?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: caption == nil ? 21 : 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint ?? theme.labelText)
            if let caption {
                Text(caption)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if let badge, badge > 0 {
                Text(badge > 99 ? "99+" : "\(badge)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4.5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(theme.tone(.failure)))
                    .offset(x: 2, y: -2)
            }
        }
    }
}

/// A titled group inside a widget panel.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}

/// A small rounded button used in panels for quick actions.
struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(Capsule().fill(prominent ? tint : Color.primary.opacity(0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Feedback shown for a moment after a copy ("Copied").
@Observable
final class TransientFlag {
    private(set) var value: String?
    private var task: Task<Void, Never>?

    func show(_ text: String, for seconds: Double = 1.4) {
        value = text
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.value = nil
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
