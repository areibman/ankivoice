import AVFAudio
import Foundation
import Observation
import UIKit

/// Live view of the voices installed on this device.
///
/// Refreshes itself when iOS reports a change (a download finishing in the
/// Settings app) and whenever the app returns to the foreground, so screens
/// that show voice status never need a manual "check again".
@MainActor
@Observable
final class VoiceInventory {

    static let shared = VoiceInventory()

    private(set) var voices: [VoiceCatalogVoice] = []
    private var observers: [NSObjectProtocol] = []

    init(catalog: VoiceCatalogProtocol = SystemVoiceCatalog(), observesSystem: Bool = true) {
        self.catalog = catalog
        refresh()
        guard observesSystem else { return }
        let center = NotificationCenter.default
        for name in [AVSpeechSynthesizer.availableVoicesDidChangeNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    private let catalog: VoiceCatalogProtocol

    func refresh() {
        let fresh = catalog.voices(matching: "")
        if fresh != voices { voices = fresh }
    }

    // MARK: Queries

    /// Every installed voice for a language ("en"), novelty voices included.
    func voices(forLanguage key: String) -> [VoiceCatalogVoice] {
        voices.filter { $0.languageKey == key }
    }

    /// The voice that will actually read `locale`: an explicit choice when
    /// one is installed (`override` first — a deck's own pick — then the
    /// user's per-language default), otherwise Automatic's pick.
    func effectiveVoice(for locale: String, settings: SettingsStore, override: String? = nil) -> VoiceCatalogVoice? {
        chosenVoice(for: locale, settings: settings, override: override)
            ?? automaticVoice(for: locale, preferredQuality: settings.voiceQuality)
    }

    /// The explicitly chosen voice for `locale`, if it's still installed and
    /// speaks that language. Nil means Automatic is in charge.
    func chosenVoice(for locale: String, settings: SettingsStore, override: String? = nil) -> VoiceCatalogVoice? {
        let localized = voices(forLanguage: SettingsStore.languageKey(for: locale))
        for identifier in [override, settings.defaultVoice(forLocale: locale)].compactMap({ $0 }) {
            if let voice = localized.first(where: { $0.identifier == identifier }) { return voice }
        }
        return nil
    }

    /// What Automatic picks for `locale`, ignoring any explicit choice:
    /// Premium, then Enhanced, then built-in, preferring the exact region.
    /// Nil when the language has no voice at all.
    func automaticVoice(for locale: String, preferredQuality: SettingsStore.VoiceQuality = .auto) -> VoiceCatalogVoice? {
        let localized = voices(forLanguage: SettingsStore.languageKey(for: locale))
        let id = TextToSpeech.VoiceSelector.best(
            localized: localized,
            allVoices: voices,
            requestedLocale: locale,
            preferredQuality: preferredQuality
        )
        guard let id, let voice = localized.first(where: { $0.identifier == id }) else { return nil }
        return voice
    }

    /// Best quality tier installed for a language, ignoring novelty voices.
    func bestTier(forLanguage key: String) -> VoiceQualityTier? {
        voices(forLanguage: key).filter(\.isAutoEligible).map(\.quality).max()
    }

    /// Whether the language can only be spoken by the robotic built-in voice.
    func hasOnlyCompactVoices(forLanguage key: String) -> Bool {
        bestTier(forLanguage: key) == .compact
    }
}

/// What the app can say about speech quality for one language: which voice
/// will read it, whether the user picked that voice themselves, and whether
/// a more natural voice is sitting installed but unused.
struct VoiceQualityStatus: Equatable {
    /// The voice that will read cards in this language; nil when none is installed.
    let voice: VoiceCatalogVoice?
    /// True when `voice` is an explicit pick (deck or Settings) rather than Automatic's.
    let isExplicit: Bool
    /// A more natural installed voice that isn't being used. Only possible
    /// after an explicit pick — Automatic always takes the best one.
    let betterInstalled: VoiceCatalogVoice?

    /// - Parameter deckVoice: a deck's own voice identifier, which outranks
    ///   the Settings default when set.
    @MainActor
    init(locale: String, inventory: VoiceInventory, settings: SettingsStore, deckVoice: String? = nil) {
        let chosen = inventory.chosenVoice(for: locale, settings: settings, override: deckVoice)
        let automatic = inventory.automaticVoice(for: locale, preferredQuality: settings.voiceQuality)
        self.init(voice: chosen ?? automatic, isExplicit: chosen != nil, best: automatic)
    }

    /// Test-friendly initializer: `best` is what Automatic would pick.
    init(voice: VoiceCatalogVoice?, isExplicit: Bool, best: VoiceCatalogVoice?) {
        self.voice = voice
        self.isExplicit = isExplicit
        if let voice, let best, best.quality > voice.quality {
            self.betterInstalled = best
        } else {
            self.betterInstalled = nil
        }
    }

    var tier: VoiceQualityTier? { voice?.quality }

    var isMissing: Bool { voice == nil }

    /// Enhanced or Premium — anything better than the robotic built-in voice.
    var isNatural: Bool {
        guard let tier else { return false }
        return tier > .compact
    }

    var isPremium: Bool { tier == .premium }

    /// "Ava · Premium", "Samantha · built-in", "No voice installed".
    var summary: String {
        guard let voice else { return "No voice installed" }
        return "\(voice.name) · \(Self.tierLabel(voice.quality))"
    }

    static func tierLabel(_ tier: VoiceQualityTier) -> String {
        switch tier {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .compact: return "built-in"
        }
    }
}
