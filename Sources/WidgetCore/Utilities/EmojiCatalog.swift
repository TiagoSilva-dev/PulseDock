import Foundation

/// A compact, curated emoji palette grouped like the system picker, plus usage ranking.
public nonisolated enum EmojiCatalog {
    public enum Group: String, CaseIterable, Sendable {
        case smileys, gestures, hearts, objects, nature, food, symbols, flags

        public var symbol: String {
            switch self {
            case .smileys: "face.smiling"
            case .gestures: "hand.raised"
            case .hearts: "heart"
            case .objects: "lightbulb"
            case .nature: "leaf"
            case .food: "fork.knife"
            case .symbols: "checkmark.seal"
            case .flags: "flag"
            }
        }

        public var emoji: [String] {
            switch self {
            case .smileys: ["😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "😉", "😊", "😇", "🥰", "😍", "🤩", "😘", "😋", "😛", "😜", "🤪", "🤔", "🤨", "😐", "😑", "😶", "🙄", "😏", "😬", "😌", "😴", "🤯", "🥳", "😎", "🤓", "🧐", "😕", "😟", "😮", "😲", "🥺", "😢", "😭", "😱", "😤", "😡", "🤬", "💀", "🤡", "👻", "🤖"]
            case .gestures: ["👍", "👎", "👌", "🤌", "✌️", "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "👇", "☝️", "✋", "🤚", "🖐️", "👋", "👏", "🙌", "👐", "🤲", "🙏", "✍️", "💪", "🫶", "🤝", "🫡", "🤷", "🤦", "🙋", "🙆", "🙅", "💁", "🧑‍💻"]
            case .hearts: ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "❤️‍🔥", "💯", "✨", "⭐️", "🌟", "💫", "🔥", "🎉", "🎊"]
            case .objects: ["💻", "🖥️", "⌨️", "🖱️", "📱", "⌚️", "📷", "🎧", "🎮", "💡", "🔋", "🔌", "🧰", "🔧", "🔨", "⚙️", "🧪", "🔬", "📦", "📁", "📝", "📌", "📎", "✂️", "🔒", "🔑", "🗓️", "⏰", "☕️", "🚀", "🛠️", "🐛", "📈", "📉", "🧠"]
            case .nature: ["🐶", "🐱", "🦊", "🐻", "🐼", "🐨", "🦁", "🐸", "🐵", "🐧", "🐦", "🦄", "🐝", "🦋", "🐢", "🐙", "🐳", "🌵", "🌲", "🌴", "🌱", "🍀", "🌸", "🌻", "🌈", "☀️", "🌙", "⛅️", "🌧️", "❄️", "🌊"]
            case .food: ["🍎", "🍌", "🍉", "🍇", "🍓", "🥑", "🌽", "🥕", "🍞", "🧀", "🍔", "🍟", "🍕", "🌮", "🍣", "🍜", "🍩", "🍪", "🎂", "🍫", "🍿", "🍺", "🍷", "🥤", "🧋", "🍵"]
            case .symbols: ["✅", "☑️", "✔️", "❌", "❗️", "❓", "⚠️", "🚫", "⛔️", "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "⚫️", "⚪️", "➡️", "⬅️", "⬆️", "⬇️", "🔁", "🔄", "➕", "➖", "♻️", "🆕", "🆗", "🔝", "💤", "🎯", "🏁"]
            case .flags: ["🇧🇷", "🇵🇹", "🇺🇸", "🇬🇧", "🇪🇸", "🇫🇷", "🇩🇪", "🇮🇹", "🇯🇵", "🇨🇳", "🇰🇷", "🇮🇳", "🇨🇦", "🇲🇽", "🇦🇷", "🇨🇱", "🇨🇴", "🇺🇾", "🇦🇺", "🇳🇱", "🏳️‍🌈", "🏴‍☠️"]
            }
        }
    }

    /// Hand gestures and people that accept the Fitzpatrick skin-tone modifiers.
    public static let toneable: Set<String> = ["👍", "👎", "👌", "🤌", "✌️", "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "👇", "☝️", "✋", "🤚", "🖐️", "👋", "👏", "🙌", "👐", "🤲", "🙏", "✍️", "💪", "🫶", "🤝", "🫡", "🤷", "🤦", "🙋", "🙆", "🙅", "💁"]

    /// Skin tones: index 0 is the default yellow.
    public static let tones = ["", "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}"]

    /// Applies a skin tone to a toneable emoji (inserted after the base scalar, before any
    /// variation selector or ZWJ sequence).
    public static func applying(tone index: Int, to emoji: String) -> String {
        guard index > 0, index < tones.count, toneable.contains(emoji),
              let first = emoji.unicodeScalars.first else { return emoji }
        var scalars = String.UnicodeScalarView()
        scalars.append(first)
        scalars.append(contentsOf: tones[index].unicodeScalars)
        for scalar in emoji.unicodeScalars.dropFirst() where scalar.value != 0xFE0F { scalars.append(scalar) }
        return String(scalars)
    }

    /// Most used first; ties are ordered by the emoji itself, so the result is deterministic.
    public static func ranked(_ usage: [String: Int], limit: Int = 8) -> [String] {
        usage.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }

    public static let defaultFavorites = ["👍", "😂", "❤️", "🔥", "🎉", "✅", "🙏", "🚀"]
}
