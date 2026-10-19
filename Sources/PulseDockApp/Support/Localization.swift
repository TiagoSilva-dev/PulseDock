import Foundation

/// Looks up a localized string in the app bundle (`Contents/Resources/<lang>.lproj/Localizable.strings`).
/// The English text passed here is the development value and the fallback; every key must
/// also exist in `Resources/Localization/pt-BR.json` (checked by `scripts/localize.py`).
nonisolated func tr(_ key: String, _ english: String) -> String {
    Bundle.main.localizedString(forKey: key, value: english, table: nil)
}

/// Same as `tr`, with `%@`/`%d` placeholders filled in.
nonisolated func tr(_ key: String, _ english: String, _ arguments: CVarArg...) -> String {
    String(format: tr(key, english), locale: Locale.current, arguments: arguments)
}

/// Count-dependent string ("1 turn" / "2 turns"). The English forms are the development values;
/// translations live in the generated `Localizable.stringsdict`, so each language's own plural
/// rules apply (CLDR, as implemented by Foundation).
nonisolated func trp(_ key: String, one: String, other: String, _ count: Int) -> String {
    let missing = "\u{1}"
    let format = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
    guard format != missing else {
        return String(format: count == 1 ? one : other, locale: Locale.current, count)
    }
    return String.localizedStringWithFormat(format, count)
}
