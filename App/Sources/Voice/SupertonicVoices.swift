import Foundation

/// Catalog of on-device Supertonic 3 voices.
///
/// Identifiers are `supertonic3:F1` … `supertonic3:M5`. The same ten
/// speakers work in every language the model supports; Automatic never
/// picks them because the CoreML pack is a large one-time download.
enum SupertonicVoiceCatalog {

    static let identifierPrefix = "supertonic3:"

    /// Display names for the ten published style presets.
    static let presets: [(id: String, name: String, detail: String)] = [
        ("F1", "Female 1", "Female"),
        ("F2", "Female 2", "Female"),
        ("F3", "Female 3", "Female"),
        ("F4", "Female 4", "Female"),
        ("F5", "Female 5", "Female"),
        ("M1", "Male 1", "Male"),
        ("M2", "Male 2", "Male"),
        ("M3", "Male 3", "Male"),
        ("M4", "Male 4", "Male"),
        ("M5", "Male 5", "Male"),
    ]

    /// ISO 639-1 codes the model was trained on, with a representative
    /// BCP-47 tag so the picker can show a region name.
    static let languages: [(key: String, locale: String)] = [
        ("ar", "ar-SA"),
        ("bg", "bg-BG"),
        ("cs", "cs-CZ"),
        ("da", "da-DK"),
        ("de", "de-DE"),
        ("el", "el-GR"),
        ("en", "en-US"),
        ("es", "es-ES"),
        ("et", "et-EE"),
        ("fi", "fi-FI"),
        ("fr", "fr-FR"),
        ("hi", "hi-IN"),
        ("hr", "hr-HR"),
        ("hu", "hu-HU"),
        ("id", "id-ID"),
        ("it", "it-IT"),
        ("ja", "ja-JP"),
        ("ko", "ko-KR"),
        ("lt", "lt-LT"),
        ("lv", "lv-LV"),
        ("nl", "nl-NL"),
        ("pl", "pl-PL"),
        ("pt", "pt-BR"),
        ("ro", "ro-RO"),
        ("ru", "ru-RU"),
        ("sk", "sk-SK"),
        ("sl", "sl-SI"),
        ("sv", "sv-SE"),
        ("tr", "tr-TR"),
        ("uk", "uk-UA"),
        ("vi", "vi-VN"),
    ]

    static func isSupertonic(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    static func identifier(for presetID: String) -> String {
        identifierPrefix + presetID
    }

    /// Style filename stem (`F1`, `M3`) from a catalog identifier.
    static func presetID(from identifier: String) -> String? {
        guard isSupertonic(identifier) else { return nil }
        let name = String(identifier.dropFirst(identifierPrefix.count))
        return presets.contains(where: { $0.id == name }) ? name : nil
    }

    static func supports(languageKey: String) -> Bool {
        languages.contains { $0.key == languageKey }
    }

    /// ISO code passed to the synthesizer. Unsupported languages use the
    /// model's language-agnostic `"na"` tag rather than failing.
    static func synthesisLanguage(for locale: String) -> String {
        let key = SettingsStore.languageKey(for: locale)
        return supports(languageKey: key) ? key : "na"
    }

    static func voices(matching languagePrefix: String) -> [VoiceCatalogVoice] {
        if languagePrefix.isEmpty {
            return languages.flatMap(voices(for:))
        }
        let needle = languagePrefix.lowercased()
        if let lang = languages.first(where: {
            $0.locale.lowercased().hasPrefix(needle) || $0.key.lowercased().hasPrefix(needle)
        }) {
            return voices(for: lang)
        }
        // Unsupported languages still list the ten speakers; synthesis uses "na".
        let key = SettingsStore.languageKey(for: languagePrefix)
        let locale = languagePrefix.contains("-") ? languagePrefix : key
        return voices(for: (key, locale))
    }

    private static func voices(for lang: (key: String, locale: String)) -> [VoiceCatalogVoice] {
        presets.map { preset in
            VoiceCatalogVoice(
                identifier: identifier(for: preset.id),
                name: preset.name,
                language: lang.locale,
                quality: .premium,
                kind: .supertonic3
            )
        }
    }
}
