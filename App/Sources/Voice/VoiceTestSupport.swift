import Foundation
import AVFAudio

// MARK: - Voice catalog abstraction
//
// AVSpeechSynthesisVoice.speechVoices() is global and not configurable.
// We inject a catalog so voice selection can be unit-tested with deterministic
// inputs and failures (no premium voice available, multiple locales, etc.).

public struct VoiceCatalogVoice: Equatable, Hashable, Sendable, Identifiable {
    public let identifier: String
    public let name: String
    public let language: String   // BCP-47, e.g. "en-US"
    public let quality: VoiceQualityTier
    /// Novelty ("Bad News", "Bubbles"), Eloquence ("Eddy", "Grandma") and other
    /// legacy voices. Never auto-selected; hidden from the picker by default.
    public let isNovelty: Bool
    /// A Personal Voice the user trained. Selectable, never auto-selected.
    public let isPersonal: Bool

    public init(
        identifier: String,
        name: String = "",
        language: String,
        quality: VoiceQualityTier,
        isNovelty: Bool = false,
        isPersonal: Bool = false
    ) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
        self.isPersonal = isPersonal
    }

    public var id: String { identifier }

    /// Lowercase language code ("en" for "en-US").
    public var languageKey: String { SettingsStore.languageKey(for: language) }

    /// Voices that automatic selection may pick without the user asking.
    public var isAutoEligible: Bool { !isNovelty && !isPersonal }

    /// Human-readable quality tier.
    public var qualityTitle: String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .compact: return "Default"
        }
    }
}

public enum VoiceQualityTier: Int, Equatable, Hashable, Comparable, Sendable {
    case compact = 0
    case enhanced = 1
    case premium = 2
    public static func < (lhs: VoiceQualityTier, rhs: VoiceQualityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public protocol VoiceCatalogProtocol: AnyObject, Sendable {
    /// Voices whose BCP-47 tag starts with `languagePrefix` ("" = all voices).
    func voices(matching languagePrefix: String) -> [VoiceCatalogVoice]
}

/// Real implementation: thin wrapper over AVSpeechSynthesisVoice.
public final class SystemVoiceCatalog: VoiceCatalogProtocol {
    public init() {}

    public func voices(matching languagePrefix: String) -> [VoiceCatalogVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { languagePrefix.isEmpty || $0.language.lowercased().hasPrefix(languagePrefix.lowercased()) }
            .map(Self.catalogVoice)
    }

    static func catalogVoice(_ v: AVSpeechSynthesisVoice) -> VoiceCatalogVoice {
        let tier: VoiceQualityTier
        switch v.quality {
        case .premium: tier = .premium
        case .enhanced: tier = .enhanced
        default: tier = .compact
        }
        return VoiceCatalogVoice(
            identifier: v.identifier,
            name: v.name,
            language: v.language,
            quality: tier,
            isNovelty: isNovelty(v),
            isPersonal: isPersonal(v)
        )
    }

    /// Novelty and legacy voices that make the app sound broken when chosen
    /// by accident. iOS lists them alongside the real voices for en-US, and
    /// several sort *before* Samantha — which is how a fresh install ends up
    /// reading flashcards as "Bad News".
    static func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 17.0, macOS 14.0, *), v.voiceTraits.contains(.isNoveltyVoice) {
            return true
        }
        let id = v.identifier.lowercased()
        // Eloquence voices (Eddy, Flo, Grandma, Grandpa, Reed, Rocko, Sandy, Shelley).
        if id.hasPrefix("com.apple.eloquence.") { return true }
        // Legacy MacinTalk voices exposed on iOS (Albert, Bad News, Fred, Zarvox…).
        if id.hasPrefix("com.apple.speech.synthesis.voice.") { return true }
        return false
    }

    static func isPersonal(_ v: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 17.0, macOS 14.0, *) {
            return v.voiceTraits.contains(.isPersonalVoice)
        }
        return false
    }
}

/// In-memory catalog used by tests. Lets us model the real-world voice list
/// (compact + enhanced + premium, multiple locales, missing premium, novelty).
public final class InMemoryVoiceCatalog: VoiceCatalogProtocol, @unchecked Sendable {
    public var voices: [VoiceCatalogVoice]

    public init(voices: [VoiceCatalogVoice] = []) {
        self.voices = voices
    }

    public func voices(matching languagePrefix: String) -> [VoiceCatalogVoice] {
        voices.filter { languagePrefix.isEmpty || $0.language.lowercased().hasPrefix(languagePrefix.lowercased()) }
    }
}
