import XCTest
@testable import AnkiVoice
import AVFAudio
@MainActor
final class VoiceQualitySelectionTests: XCTestCase {

    private func config(preferred: SettingsStore.VoiceQuality) -> VoiceConfig {
        VoiceConfig(
            questionLocale: "en-US",
            answerLocale: "en-US",
            speechRate: 1.0,
            endpointDelayMs: 700,
            semanticGradingEnabled: false,
            preferredQuality: preferred
        )
    }

    /// Premium requested, premium voice available → must pick the premium voice
    /// for the exact locale. This is the case the user expected to hear
    /// (Ava Premium / Samantha Premium etc.).
    func testPremiumPreferencePicksPremiumVoice() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "en-US-compact", name: "Compact", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-enhanced", name: "Samantha", language: "en-US", quality: .enhanced),
            VoiceCatalogVoice(identifier: "en-US-premium", name: "Ava", language: "en-US", quality: .premium),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        let id = tts.selectVoice(locale: "en-US", config: config(preferred: .premium))
        XCTAssertEqual(id, "en-US-premium", "Premium preference must select premium voice, not compact or enhanced")
    }

    /// Premium requested but no premium voice installed for this locale →
    /// fall back to enhanced, NOT compact. (Compact sounds bad — the
    /// original user complaint.)
    func testPremiumPreferenceFallsBackToEnhancedNotCompact() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "en-US-compact", name: "Compact", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-enhanced", name: "Samantha", language: "en-US", quality: .enhanced),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        let id = tts.selectVoice(locale: "en-US", config: config(preferred: .premium))
        XCTAssertEqual(id, "en-US-enhanced", "When premium unavailable, must use enhanced — never compact")
    }

    /// Premium requested but only compact exists (the worst case) →
    /// compact is the only choice but the user should be warned.
    func testPremiumPreferenceWithOnlyCompactFallsBack() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "en-US-compact", name: "Compact", language: "en-US", quality: .compact),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        let id = tts.selectVoice(locale: "en-US", config: config(preferred: .premium))
        XCTAssertEqual(id, "en-US-compact", "Compact is the only option, fall back to it")
    }

    /// Auto preference prefers premium when present, then enhanced, then compact.
    func testAutoPreferencePicksHighestAvailable() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "en-US-compact", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-premium", language: "en-US", quality: .premium),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        let id = tts.selectVoice(locale: "en-US", config: config(preferred: .auto))
        XCTAssertEqual(id, "en-US-premium", "Auto should always pick premium when available")
    }

    /// The user's exact scenario: the device only has compact voices installed
    /// for the language. Premium + enhanced preferences must still produce a
    /// usable voice (compact in this case) — but at least the locale matches
    /// and we don't fall back to a wrong language entirely.
    func testOnlyCompactVoiceForLanguageIsStillUsable() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "ja-JP-compact", language: "ja-JP", quality: .compact),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        let id = tts.selectVoice(locale: "ja-JP", config: config(preferred: .premium))
        XCTAssertEqual(id, "ja-JP-compact", "When only compact is available for the language, use it")
    }

    /// User-selected voice (explicit identifier) overrides the quality preference.
    func testExplicitUserSelectionOverridesQualityPreference() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "en-US-compact", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-premium", language: "en-US", quality: .premium),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        var cfg = config(preferred: .enhanced)
        cfg.questionVoice = "en-US-compact"  // user picked compact explicitly
        let id = tts.selectVoice(locale: "en-US", config: cfg)
        XCTAssertEqual(id, "en-US-compact", "Explicit user voice selection must always win")
    }

    /// Locale tag mismatch: user wants Japanese, but only US English voices exist.
    /// We should still pick US English (better than failing).
    func testFallsBackToLanguageMatchWhenLocaleMissing() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "en-US-premium", language: "en-US", quality: .premium),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        let id = tts.selectVoice(locale: "ja-JP", config: config(preferred: .premium))
        XCTAssertEqual(id, "en-US-premium", "Should fall back to language match rather than failing")
    }

    /// Empty catalog (no voices for this language at all) → nil.
    func testEmptyCatalogReturnsNil() {
        let catalog = InMemoryVoiceCatalog(voices: [])
        let tts = TextToSpeech()
        tts.catalog = catalog
        let id = tts.selectVoice(locale: "en-US", config: config(preferred: .auto))
        XCTAssertNil(id)
    }

    // MARK: - Regressions behind "the weird default voice"

    /// iOS lists the en-US novelty voices (Albert, Bad News, Bubbles…) before
    /// Samantha. Auto-selection must skip them.
    func testNoveltyVoicesAreNeverAutoSelected() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "com.apple.speech.synthesis.voice.Albert", name: "Albert", language: "en-US", quality: .compact, isNovelty: true),
            VoiceCatalogVoice(identifier: "com.apple.speech.synthesis.voice.BadNews", name: "Bad News", language: "en-US", quality: .compact, isNovelty: true),
            VoiceCatalogVoice(identifier: "com.apple.eloquence.en-US.Grandma", name: "Grandma", language: "en-US", quality: .compact, isNovelty: true),
            VoiceCatalogVoice(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .compact),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        let id = tts.selectVoice(locale: "en-US", config: config(preferred: .auto))
        XCTAssertEqual(id, "com.apple.voice.compact.en-US.Samantha")
    }

    /// A novelty voice the user explicitly chose is still honored.
    func testExplicitNoveltyVoiceIsHonored() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "novelty", name: "Zarvox", language: "en-US", quality: .compact, isNovelty: true),
            VoiceCatalogVoice(identifier: "samantha", name: "Samantha", language: "en-US", quality: .compact),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        var cfg = config(preferred: .auto)
        cfg.questionVoice = "novelty"
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg.speaking(.question)), "novelty")
    }

    /// A premium voice in another language must never read this language:
    /// a compact English voice beats a premium Japanese one for English text.
    func testLanguageMatchBeatsQualityInOtherLanguage() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "ja-premium", name: "Kyoko", language: "ja-JP", quality: .premium),
            VoiceCatalogVoice(identifier: "en-compact", name: "Samantha", language: "en-US", quality: .compact),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config(preferred: .auto)), "en-compact")
        XCTAssertEqual(tts.selectVoice(locale: "ja-JP", config: config(preferred: .auto)), "ja-premium")
    }

    /// Within a language, the exact regional variant wins inside a tier but a
    /// higher tier from another region still wins overall.
    func testExactRegionPreferredWithinTier() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "en-GB-compact", language: "en-GB", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-compact", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "en-AU-enhanced", language: "en-AU", quality: .enhanced),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config(preferred: .auto)), "en-AU-enhanced")
        let compactOnly = InMemoryVoiceCatalog(voices: Array(catalog.voices.prefix(2)))
        tts.catalog = compactOnly
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config(preferred: .auto)), "en-US-compact")
    }

    /// Question and answer share a locale but use different voices: the side
    /// being spoken decides, not the locale.
    func testAnswerVoiceUsedWhenLocalesMatch() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "ava", name: "Ava", language: "en-US", quality: .premium),
            VoiceCatalogVoice(identifier: "tom", name: "Tom", language: "en-US", quality: .enhanced),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        var cfg = config(preferred: .auto)
        cfg.questionVoice = "ava"
        cfg.answerVoice = "tom"
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg.speaking(.question)), "ava")
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg.speaking(.answer)), "tom")
    }

    /// An explicit voice that isn't installed any more falls back to auto.
    func testMissingExplicitVoiceFallsBackToAuto() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "samantha", language: "en-US", quality: .enhanced),
        ])
        let tts = TextToSpeech()
        tts.catalog = catalog
        var cfg = config(preferred: .auto)
        cfg.questionVoice = "deleted-voice"
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg.speaking(.question)), "samantha")
    }

    /// Default voices are keyed by language so one choice covers every region.
    func testDefaultVoiceIsPerLanguage() {
        let defaults = UserDefaults(suiteName: "VoiceDefaults-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.setDefaultVoice("ava", forLocale: "en-US")
        XCTAssertEqual(settings.defaultVoice(forLocale: "en-GB"), "ava")
        XCTAssertEqual(settings.defaultVoice(forLocale: "en"), "ava")
        XCTAssertNil(settings.defaultVoice(forLocale: "ja-JP"))
        settings.setDefaultVoice(nil, forLocale: "en-AU")
        XCTAssertNil(settings.defaultVoice(forLocale: "en-US"))
    }

    func testSpeechRateIsClampedAndDefaultsToNormal() {
        let defaults = UserDefaults(suiteName: "VoiceRate-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.speechRate, 1.0)
        settings.speechRate = 5
        XCTAssertEqual(settings.speechRate, 2.0)
        settings.speechRate = 0.1
        XCTAssertEqual(settings.speechRate, 0.5)
    }
}
