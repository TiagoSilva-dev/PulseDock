import AppKit
import DockRendering
import SwiftUI
import WidgetCore

// MARK: - Clipboard

struct ClipboardTile: View {
    let history: ClipboardHistory
    let theme: Theme

    var body: some View {
        SymbolTile(symbol: history.isPaused ? "pause.circle" : "doc.on.clipboard", theme: theme,
                   caption: history.items.isEmpty ? nil : "\(history.items.count)")
            .accessibilityLabel(tr("widget.clipboard", "Clipboard"))
            .accessibilityValue(trp("clipboard.count", one: "%ld item", other: "%ld items", history.items.count))
    }
}

struct ClipboardPanel: View {
    let history: ClipboardHistory
    let theme: Theme
    let accessibility: AccessibilityOptions
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.clipboard", "Clipboard")) {
            HStack(spacing: 6) {
                TextField(tr("clipboard.search", "Search"), text: $query).textFieldStyle(.roundedBorder)
                Toggle(isOn: Binding(get: { !history.isPaused }, set: { history.isPaused = !$0 })) {
                    Text(tr("clipboard.recording", "Record"))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            switch history.access {
            case .allowed: EmptyView()
            case .needsPermission:
                AccessPrompt(text: tr("clipboard.access.prompt", "macOS asks before an app reads what you copy. To keep a history without alerts, choose “Always Allow” for PulseDock in System Settings › Privacy & Security › Paste from Other Apps."),
                             button: tr("clipboard.access.start", "Start Recording…"), theme: theme) {
                    history.requestAccess()
                    SystemSettingsLink.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
                }
            case .denied:
                Text(tr("clipboard.access.denied", "Paste access for PulseDock is set to “Always Deny” in System Settings › Privacy & Security › Paste from Other Apps."))
                    .font(PulseTypography.panelCaption).foregroundStyle(theme.tone(.attention)).fixedSize(horizontal: false, vertical: true)
            }
            let items = history.items.filter { query.isEmpty || $0.preview.localizedCaseInsensitiveContains(query) }
            if items.isEmpty, history.access == .allowed {
                Text(history.items.isEmpty ? tr("clipboard.empty", "Copy something and it appears here.") : tr("clipboard.noMatch", "Nothing matches."))
                    .font(PulseTypography.panelBody).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(items) { item in row(item) }
                }
            }
            HStack {
                Text(tr("clipboard.footer", "Kept in memory only; pinned text survives a restart. Passwords marked as concealed are never recorded."))
                    .font(PulseTypography.panelCaption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button(tr("clipboard.clear", "Clear")) { history.clearUnpinned() }.buttonStyle(.link).font(PulseTypography.panelCaption)
            }
        }
        .onAppear { history.refreshAccess() }
    }

    private func row(_ item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            Group {
                switch item.content {
                case let .image(data):
                    if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 34, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                case .files: Image(systemName: "doc").frame(width: 34)
                case .text: Image(systemName: "text.alignleft").foregroundStyle(.secondary).frame(width: 34)
                }
            }
            Text(item.preview.isEmpty ? tr("clipboard.image", "Image") : item.preview)
                .font(PulseTypography.panelBody)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { history.togglePin(item) } label: {
                Image(systemName: item.isPinned ? "pin.fill" : "pin").font(.system(size: 11)).foregroundStyle(item.isPinned ? theme.tone(.attention) : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isPinned ? tr("clipboard.unpin", "Unpin") : tr("clipboard.pin", "Pin"))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onTapGesture {
            history.copy(item)
            dismiss()
        }
        .contextMenu {
            Button(tr("clipboard.copy", "Copy")) { history.copy(item) }
            Button(item.isPinned ? tr("clipboard.unpin", "Unpin") : tr("clipboard.pin", "Pin")) { history.togglePin(item) }
            Button(tr("clipboard.delete", "Delete")) { history.remove(item) }
        }
        .help(tr("clipboard.clickToCopy", "Click to copy again"))
    }
}

// MARK: - Color Picker

enum ColorFormat {
    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    static func color(hex: String) -> NSColor? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, alpha: 1)
    }

    static func rgb(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
        return "rgb(\(Int((rgb.redComponent * 255).rounded())), \(Int((rgb.greenComponent * 255).rounded())), \(Int((rgb.blueComponent * 255).rounded())))"
    }

    static func hsl(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        var h = 0.0, s = 0.0
        if maxV != minV {
            let d = maxV - minV
            s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
            switch maxV {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h /= 6
        }
        return "hsl(\(Int((h * 360).rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }

    static func swiftUI(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
        return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }
}

struct ColorPickerTile: View {
    let recent: [String]
    let theme: Theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SymbolTile(symbol: "eyedropper.halffull", theme: theme)
            if let last = recent.first, let color = ColorFormat.color(hex: last) {
                Circle().fill(Color(nsColor: color))
                    .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.2))
                    .frame(width: 13, height: 13)
                    .padding(5)
            }
        }
        .accessibilityLabel(tr("widget.colorPicker", "Color Picker"))
        .accessibilityValue(recent.first ?? "")
    }
}

struct ColorPickerPanel: View {
    let data: WidgetDataStore
    let theme: Theme
    let accessibility: AccessibilityOptions
    let pick: () -> Void
    @State private var copied = TransientFlag()

    var body: some View {
        let colors = data.data.recentColors
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.colorPicker", "Color Picker")) {
            PillButton(title: tr("color.pick", "Pick a Color on Screen"), symbol: "eyedropper", prominent: true, tint: theme.tone(.working), action: pick)
            if let hex = colors.first, let color = ColorFormat.color(hex: hex) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: color)).frame(width: 54, height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 3) {
                        formatRow(ColorFormat.hex(color))
                        formatRow(ColorFormat.rgb(color))
                        formatRow(ColorFormat.hsl(color))
                        formatRow(ColorFormat.swiftUI(color))
                    }
                }
            }
            if colors.count > 1 {
                PanelSection(title: tr("color.recent", "Recent")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 9), spacing: 6) {
                        ForEach(colors, id: \.self) { hex in
                            if let color = ColorFormat.color(hex: hex) {
                                Button {
                                    Pasteboard.copy(hex)
                                    copied.show(tr("color.copiedValue", "Copied %@", hex))
                                    data.update { store in
                                        store.recentColors.removeAll { $0 == hex }
                                        store.recentColors.insert(hex, at: 0)
                                    }
                                } label: {
                                    Circle().fill(Color(nsColor: color)).frame(width: 24, height: 24)
                                        .overlay(Circle().stroke(Color.primary.opacity(0.15)))
                                }
                                .buttonStyle(.plain)
                                .help(hex)
                            }
                        }
                    }
                }
            }
            Text(copied.value ?? tr("color.footer", "Click a value to copy it. Picking copies the HEX code."))
                .font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
        }
    }

    private func formatRow(_ value: String) -> some View {
        Button {
            Pasteboard.copy(value)
            copied.show(tr("color.copiedValue", "Copied %@", value))
        } label: {
            Text(value).font(PulseTypography.mono).lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Emoji

struct EmojiTile: View {
    let favorites: [String]

    var body: some View {
        Text(favorites.first ?? "😀")
            .font(.system(size: 26))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(tr("widget.emoji", "Emoji"))
    }
}

struct EmojiPanel: View {
    let data: WidgetDataStore
    let theme: Theme
    let accessibility: AccessibilityOptions
    @State private var group: EmojiCatalog.Group = .smileys
    @State private var copied = TransientFlag()

    var body: some View {
        let ranked = EmojiCatalog.ranked(data.data.emojiUsage)
        let favorites = ranked.isEmpty ? EmojiCatalog.defaultFavorites : ranked
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.emoji", "Emoji")) {
            PanelSection(title: tr("emoji.frequent", "Most used")) {
                HStack(spacing: 4) {
                    ForEach(favorites, id: \.self) { emoji in cell(emoji) }
                }
            }
            HStack(spacing: 2) {
                ForEach(EmojiCatalog.Group.allCases, id: \.self) { candidate in
                    Button { group = candidate } label: {
                        Image(systemName: candidate.symbol)
                            .font(.system(size: 12))
                            .frame(width: 30, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(group == candidate ? Color.primary.opacity(0.12) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 9), spacing: 2) {
                    ForEach(group.emoji, id: \.self) { emoji in cell(emoji) }
                }
            }
            HStack(spacing: 6) {
                Text(copied.value ?? tr("emoji.footer", "Click to copy, then paste with ⌘V."))
                    .font(PulseTypography.panelCaption).foregroundStyle(.tertiary)
                Spacer()
                ForEach(0..<EmojiCatalog.tones.count, id: \.self) { tone in
                    Button { data.update { $0.emojiTone = tone } } label: {
                        Text(EmojiCatalog.applying(tone: tone, to: "👋")).font(.system(size: 13))
                            .padding(2)
                            .background(Circle().fill(data.data.emojiTone == tone ? Color.primary.opacity(0.15) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func cell(_ base: String) -> some View {
        let emoji = EmojiCatalog.applying(tone: data.data.emojiTone, to: base)
        return Button {
            Pasteboard.copy(emoji)
            data.update { $0.emojiUsage[base, default: 0] += 1 }
            copied.show(tr("emoji.copied", "%@ copied", emoji))
        } label: {
            Text(emoji).font(.system(size: 21)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Converter

struct ConverterPanel: View {
    let theme: Theme
    let accessibility: AccessibilityOptions
    @State private var family: ConversionFamily = .length
    @State private var input = "1"
    @State private var from = 2
    @State private var to = 6

    var body: some View {
        let units = family.units
        let source = units[safe: from] ?? units[0]
        let target = units[safe: to] ?? units[min(1, units.count - 1)]
        let result = UnitConverter.parse(input).flatMap { UnitConverter.convert($0, from: source, to: target) }
        WidgetPanelContainer(theme: theme, accessibility: accessibility, title: tr("widget.converter", "Converter")) {
            Picker(tr("converter.family", "Kind"), selection: $family) {
                ForEach(ConversionFamily.allCases, id: \.self) { candidate in
                    Label(familyName(candidate), systemImage: candidate.symbol).tag(candidate)
                }
            }
            .labelsHidden()
            .onChange(of: family) {
                from = 0
                to = min(1, family.units.count - 1)
            }
            HStack(spacing: 8) {
                TextField("1", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .frame(width: 110)
                unitPicker($from, units: units)
            }
            HStack {
                Button {
                    swap(&from, &to)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(tr("converter.swap", "Swap units"))
                Spacer()
            }
            HStack(spacing: 8) {
                Text(result.map { UnitConverter.format($0) } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .textSelection(.enabled)
                    .frame(width: 110, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                unitPicker($to, units: units)
            }
            if let result {
                Button(tr("converter.copy", "Copy result")) { Pasteboard.copy(UnitConverter.format(result)) }
                    .buttonStyle(.link).font(PulseTypography.panelCaption)
            }
        }
    }

    private func unitPicker(_ selection: Binding<Int>, units: [Dimension]) -> some View {
        Picker("", selection: selection) {
            ForEach(Array(units.enumerated()), id: \.offset) { index, unit in
                Text(UnitConverter.unitName(unit)).tag(index)
            }
        }
        .labelsHidden()
    }

    private func familyName(_ family: ConversionFamily) -> String {
        switch family {
        case .length: tr("converter.length", "Length")
        case .mass: tr("converter.mass", "Weight")
        case .temperature: tr("converter.temperature", "Temperature")
        case .volume: tr("converter.volume", "Volume")
        case .speed: tr("converter.speed", "Speed")
        case .data: tr("converter.data", "Data")
        case .time: tr("converter.time", "Time")
        case .area: tr("converter.area", "Area")
        }
    }
}
