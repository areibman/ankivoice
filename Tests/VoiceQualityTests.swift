import XCTest
@testable import AnkiVoice
import AVFAudio

/// Automatic voice selection: best installed tier for the language, exact
/// region preferred within a tier, novelty voices skipped, explicit picks win.
@MainActor
final class VoiceQualitySelectionTests: XCTestCase {

    private func config() -> VoiceConfig {
        VoiceConfig(questionLocale: "en-US", answerLocale: "en-US", speechRate: 1.0)
    }

    private func makeTTS(_ voices: [VoiceCatalogVoice]) -> TextToSpeech {
        let tts = TextToSpeech()
        tts.catalog = InMemoryVoiceCatalog(voices: voices)
        return tts
    }

    func testPicksPremiumOverEnhancedOverCompact() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "en-US-compact", name: "Compact", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-enhanced", name: "Samantha", language: "en-US", quality: .enhanced),
            VoiceCatalogVoice(identifier: "en-US-premium", name: "Ava", language: "en-US", quality: .premium),
        ])
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config()), "en-US-premium")
    }

    /// The robotic compact voice is only ever used when nothing better is installed.
    func testEnhancedBeatsCompact() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "en-US-compact", name: "Compact", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-enhanced", name: "Samantha", language: "en-US", quality: .enhanced),
        ])
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config()), "en-US-enhanced")
    }

    func testCompactIsUsedWhenItIsTheOnlyVoiceForTheLanguage() {
        let tts = makeTTS([VoiceCatalogVoice(identifier: "ja-JP-compact", language: "ja-JP", quality: .compact)])
        XCTAssertEqual(tts.selectVoice(locale: "ja-JP", config: config()), "ja-JP-compact")
    }

    /// An explicit voice always wins over Automatic, whatever its quality.
    func testExplicitUserSelectionOverridesAutomatic() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "en-US-compact", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-premium", language: "en-US", quality: .premium),
        ])
        var cfg = config()
        cfg.questionVoice = "en-US-compact"
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg), "en-US-compact")
    }

    /// Locale mismatch: Japanese requested, only US English installed → still
    /// pick English rather than failing.
    func testFallsBackToLanguageMatchWhenLocaleMissing() {
        let tts = makeTTS([VoiceCatalogVoice(identifier: "en-US-premium", language: "en-US", quality: .premium)])
        XCTAssertEqual(tts.selectVoice(locale: "ja-JP", config: config()), "en-US-premium")
    }

    func testEmptyCatalogReturnsNil() {
        XCTAssertNil(makeTTS([]).selectVoice(locale: "en-US", config: config()))
    }

    /// Voice catalog filtering is by language prefix, so en-GB serves en-US.
    func testCatalogLanguagePrefixFiltering() {
        let catalog = InMemoryVoiceCatalog(voices: [
            VoiceCatalogVoice(identifier: "en-US", name: "Samantha", language: "en-US", quality: .enhanced),
            VoiceCatalogVoice(identifier: "en-GB", name: "Daniel", language: "en-GB", quality: .compact),
            VoiceCatalogVoice(identifier: "fr-FR", name: "Amelie", language: "fr-FR", quality: .compact),
        ])
        let enVoices = catalog.voices(matching: "en")
        XCTAssertEqual(enVoices.count, 2)
        XCTAssertTrue(enVoices.allSatisfy { $0.language.hasPrefix("en") })
    }

    // MARK: - Regressions behind "the weird default voice"

    /// iOS lists the en-US novelty voices (Albert, Bad News, Bubbles…) before
    /// Samantha. Auto-selection must skip them.
    func testNoveltyVoicesAreNeverAutoSelected() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "com.apple.speech.synthesis.voice.Albert", name: "Albert", language: "en-US", quality: .compact, isNovelty: true),
            VoiceCatalogVoice(identifier: "com.apple.speech.synthesis.voice.BadNews", name: "Bad News", language: "en-US", quality: .compact, isNovelty: true),
            VoiceCatalogVoice(identifier: "com.apple.eloquence.en-US.Grandma", name: "Grandma", language: "en-US", quality: .compact, isNovelty: true),
            VoiceCatalogVoice(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .compact),
        ])
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config()), "com.apple.voice.compact.en-US.Samantha")
    }

    /// A novelty voice the user explicitly chose is still honored.
    func testExplicitNoveltyVoiceIsHonored() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "novelty", name: "Zarvox", language: "en-US", quality: .compact, isNovelty: true),
            VoiceCatalogVoice(identifier: "samantha", name: "Samantha", language: "en-US", quality: .compact),
        ])
        var cfg = config()
        cfg.questionVoice = "novelty"
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg.speaking(.question)), "novelty")
    }

    /// A premium voice in another language must never read this language:
    /// a compact English voice beats a premium Japanese one for English text.
    func testLanguageMatchBeatsQualityInOtherLanguage() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "ja-premium", name: "Kyoko", language: "ja-JP", quality: .premium),
            VoiceCatalogVoice(identifier: "en-compact", name: "Samantha", language: "en-US", quality: .compact),
        ])
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config()), "en-compact")
        XCTAssertEqual(tts.selectVoice(locale: "ja-JP", config: config()), "ja-premium")
    }

    /// Within a language, the exact regional variant wins inside a tier but a
    /// higher tier from another region still wins overall.
    func testExactRegionPreferredWithinTier() {
        let all = [
            VoiceCatalogVoice(identifier: "en-GB-compact", language: "en-GB", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-compact", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "en-AU-enhanced", language: "en-AU", quality: .enhanced),
        ]
        let tts = makeTTS(all)
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config()), "en-AU-enhanced")
        tts.catalog = InMemoryVoiceCatalog(voices: Array(all.prefix(2)))
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config()), "en-US-compact")
    }

    /// Question and answer share a locale but use different voices: the side
    /// being spoken decides, not the locale.
    func testAnswerVoiceUsedWhenLocalesMatch() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "ava", name: "Ava", language: "en-US", quality: .premium),
            VoiceCatalogVoice(identifier: "tom", name: "Tom", language: "en-US", quality: .enhanced),
        ])
        var cfg = config()
        cfg.questionVoice = "ava"
        cfg.answerVoice = "tom"
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg.speaking(.question)), "ava")
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg.speaking(.answer)), "tom")
    }

    /// The voice chosen for a side stays when the text is another language.
    /// Foreign decks used to hop to a new speaker for every detected script.
    func testExplicitVoiceStaysWhenTheChunkLanguageDiffers() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "ja-JP-compact", name: "Kyoko", language: "ja-JP", quality: .compact),
            VoiceCatalogVoice(identifier: "en-US-premium", name: "Ava", language: "en-US", quality: .premium),
            VoiceCatalogVoice(identifier: "supertonic3:F1", name: "Female 1", language: "en-US", quality: .premium, kind: .supertonic3),
        ])
        var cfg = VoiceConfig(questionLocale: "ja-JP", answerLocale: "en-US", speechRate: 1)
        cfg.questionVoice = "ja-JP-compact"
        cfg.answerVoice = "en-US-premium"
        cfg.languageVoices = ["en": "en-US-premium", "ja": "supertonic3:F1"]
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg.speaking(.question)), "ja-JP-compact")
        XCTAssertEqual(tts.selectVoice(locale: "ja-JP", config: cfg.speaking(.question)), "ja-JP-compact")
        XCTAssertEqual(tts.selectVoice(locale: "ja-JP", config: cfg.speaking(.answer)), "en-US-premium")
    }

    /// An explicit voice that isn't installed any more falls back to Automatic.
    func testMissingExplicitVoiceFallsBackToAutomatic() {
        let tts = makeTTS([VoiceCatalogVoice(identifier: "samantha", language: "en-US", quality: .enhanced)])
        var cfg = config()
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
        XCTAssertNil(settings.effectiveDefaultVoice(forLocale: "ja-JP"))
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

    // MARK: - Supertonic 3

    func testSupertonicVoicesAreNeverAutoSelected() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "samantha", name: "Samantha", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "supertonic3:F1", name: "Female 1", language: "en-US", quality: .premium, kind: .supertonic3),
        ])
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: config()), "samantha")
    }

    /// Picking Female 1 for English keeps her when a side is switched to
    /// Japanese and that language has no voice of its own.
    func testSupertonicChoiceCarriesToALanguageWithoutAPick() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "ja-JP-compact", name: "Kyoko", language: "ja-JP", quality: .compact),
            VoiceCatalogVoice(identifier: "supertonic3:F1", name: "Female 1", language: "en-US", quality: .premium, kind: .supertonic3),
        ])
        var cfg = VoiceConfig(questionLocale: "ja-JP", answerLocale: "en-US", speechRate: 1)
        cfg.languageVoices = ["en": "supertonic3:F1"]
        XCTAssertEqual(tts.selectVoice(locale: "ja-JP", config: cfg.speaking(.question)), "supertonic3:F1")

        let defaults = UserDefaults(suiteName: "VoiceCarry-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.setDefaultVoice("supertonic3:F1", forLocale: "en-US")
        XCTAssertEqual(settings.effectiveDefaultVoice(forLocale: "ja-JP"), "supertonic3:F1")
        settings.setDefaultVoice("ja-JP-compact", forLocale: "ja-JP")
        XCTAssertEqual(settings.effectiveDefaultVoice(forLocale: "ja-JP"), "ja-JP-compact")
    }

    func testExplicitSupertonicVoiceIsHonored() {
        let tts = makeTTS([
            VoiceCatalogVoice(identifier: "samantha", language: "en-US", quality: .compact),
            VoiceCatalogVoice(identifier: "supertonic3:M1", name: "Male 1", language: "en-US", quality: .premium, kind: .supertonic3),
        ])
        var cfg = config()
        cfg.questionVoice = "supertonic3:M1"
        XCTAssertEqual(tts.selectVoice(locale: "en-US", config: cfg.speaking(.question)), "supertonic3:M1")
    }

    func testSupertonicCatalogCoversSupportedLanguagesOnly() {
        let english = SupertonicVoiceCatalog.voices(matching: "en")
        XCTAssertEqual(english.count, 10)
        XCTAssertTrue(english.allSatisfy { $0.kind == .supertonic3 && $0.languageKey == "en" && !$0.isAutoEligible })
        XCTAssertEqual(SupertonicVoiceCatalog.voices(matching: "zh").count, 10)
        XCTAssertTrue(SupertonicVoiceCatalog.supports(languageKey: "ja"))
        XCTAssertFalse(SupertonicVoiceCatalog.supports(languageKey: "zh"))
        XCTAssertEqual(SupertonicVoiceCatalog.synthesisLanguage(for: "ja-JP"), "ja")
        XCTAssertEqual(SupertonicVoiceCatalog.synthesisLanguage(for: "zh-CN"), "na")
        XCTAssertEqual(SupertonicVoiceCatalog.presetID(from: "supertonic3:F3"), "F3")
        XCTAssertNil(SupertonicVoiceCatalog.presetID(from: "com.apple.voice.compact.en-US.Samantha"))
    }

    func testWavHeaderIs44BytesPlusPCM() {
        let samples: [Float] = [0, 0.5, -0.5, 1]
        let data = PCMWav.data(samples: samples, sampleRate: 44_100)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
    }
}
