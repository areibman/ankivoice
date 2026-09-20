import XCTest
import Observation
@testable import AnkiVoice

/// Guards the plumbing that makes choosing a voice *visible*: settings must
/// notify observers (SwiftUI) when they change, and the status shown next to
/// a voice must describe what was picked, not just what's installed.
@MainActor
final class VoiceSelectionUITests: XCTestCase {

    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "VoiceSelectionUI-\(UUID().uuidString)")!)
    }

    /// `withObservationTracking`'s onChange is `@Sendable`; this lets it flip
    /// a flag the test can read afterwards. The callback runs synchronously
    /// inside the mutation, on the main actor, so no real race exists.
    private final class Flag: @unchecked Sendable {
        var value = false
    }

    /// Runs `read` under observation, then `write`, and reports whether the
    /// observer was notified.
    private func notifies(_ settings: SettingsStore, read: (SettingsStore) -> Void, write: (SettingsStore) -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking {
            read(settings)
        } onChange: {
            flag.value = true
        }
        write(settings)
        return flag.value
    }

    // MARK: SettingsStore observation

    /// The regression that made voice selection look broken: SettingsStore's
    /// properties are computed over UserDefaults, which `@Observable` can't
    /// track by itself. Every read must register and every write must fire.
    func testChangingDefaultVoiceNotifiesObservers() {
        let settings = makeSettings()
        XCTAssertTrue(notifies(
            settings,
            read: { _ = $0.defaultVoice(forLocale: "en-US") },
            write: { $0.setDefaultVoice("com.apple.voice.compact.en-AU.Karen", forLocale: "en-GB") }
        ))
        XCTAssertEqual(settings.defaultVoice(forLocale: "en-US"), "com.apple.voice.compact.en-AU.Karen")
    }

    func testEverySettingNotifiesObservers() {
        let settings = makeSettings()
        // (read, write) pairs for each persisted property.
        let cases: [(String, (SettingsStore) -> Void, (SettingsStore) -> Void)] = [
            ("onboardingComplete", { _ = $0.onboardingComplete }, { $0.onboardingComplete = true }),
            ("endpointProfile", { _ = $0.endpointProfile }, { $0.endpointProfile = .fast }),
            ("answerTimeoutSeconds", { _ = $0.answerTimeoutSeconds }, { $0.answerTimeoutSeconds = 75 }),
            ("requireSpokenAnswer", { _ = $0.requireSpokenAnswer }, { $0.requireSpokenAnswer = false }),
            ("allowRevealCommand", { _ = $0.allowRevealCommand }, { $0.allowRevealCommand = false }),
            ("announceRatingConfirmation", { _ = $0.announceRatingConfirmation }, { $0.announceRatingConfirmation = true }),
            ("announceNextInterval", { _ = $0.announceNextInterval }, { $0.announceNextInterval = true }),
            ("autoStartNextCard", { _ = $0.autoStartNextCard }, { $0.autoStartNextCard = false }),
            ("pauseWhenHeadphonesDisconnect", { _ = $0.pauseWhenHeadphonesDisconnect }, { $0.pauseWhenHeadphonesDisconnect = false }),
            ("simplifiedRatings", { _ = $0.simplifiedRatings }, { $0.simplifiedRatings = true }),
            ("commandLocale", { _ = $0.commandLocale }, { $0.commandLocale = "en-GB" }),
            ("sampleContentSeeded", { _ = $0.sampleContentSeeded }, { $0.sampleContentSeeded = true }),
            ("speechRate", { _ = $0.speechRate }, { $0.speechRate = 1.3 }),
            ("defaultVoices", { _ = $0.defaultVoices }, { $0.defaultVoices = ["ja": "kyoko"] }),
            ("ankiConnectHost", { _ = $0.ankiConnectHost }, { $0.ankiConnectHost = "mac.local" }),
            ("ankiConnectPort", { _ = $0.ankiConnectPort }, { $0.ankiConnectPort = 9000 }),
            ("ankiConnectKey", { _ = $0.ankiConnectKey }, { $0.ankiConnectKey = "k" }),
        ]
        for (name, read, write) in cases {
            XCTAssertTrue(notifies(settings, read: read, write: write), "\(name) changed without notifying observers")
        }
    }

    /// Unrelated settings must not wake observers of the voice choice, or
    /// every screen would redraw on every toggle.
    func testUnrelatedSettingDoesNotNotify() {
        let settings = makeSettings()
        XCTAssertFalse(notifies(
            settings,
            read: { _ = $0.defaultVoice(forLocale: "en-US") },
            write: { $0.simplifiedRatings = true }
        ))
    }

    // MARK: VoiceQualityStatus

    private let samantha = VoiceCatalogVoice(identifier: "samantha", name: "Samantha", language: "en-US", quality: .compact)
    private let karen = VoiceCatalogVoice(identifier: "karen", name: "Karen", language: "en-AU", quality: .compact)
    private let ava = VoiceCatalogVoice(identifier: "ava", name: "Ava", language: "en-US", quality: .premium)
    private let tom = VoiceCatalogVoice(identifier: "tom", name: "Tom", language: "en-US", quality: .enhanced)
    private let kyoko = VoiceCatalogVoice(identifier: "kyoko", name: "Kyoko", language: "ja-JP", quality: .compact)

    private func inventory(_ voices: [VoiceCatalogVoice]) -> VoiceInventory {
        VoiceInventory(catalog: InMemoryVoiceCatalog(voices: voices), observesSystem: false)
    }

    /// Fresh install: only the compact voice, Automatic in charge.
    func testCompactOnlyIsRoboticAndNotExplicit() {
        let status = VoiceQualityStatus(locale: "en-US", inventory: inventory([samantha, karen]), settings: makeSettings())
        XCTAssertEqual(status.voice, samantha)
        XCTAssertFalse(status.isExplicit)
        XCTAssertFalse(status.isNatural)
        XCTAssertNil(status.betterInstalled)
    }

    /// Tapping a voice in the picker must be reflected as *that* voice,
    /// flagged as the user's own pick.
    func testExplicitPickIsReported() {
        let settings = makeSettings()
        settings.setDefaultVoice("karen", forLocale: "en-US")
        let status = VoiceQualityStatus(locale: "en-US", inventory: inventory([samantha, karen]), settings: settings)
        XCTAssertEqual(status.voice, karen)
        XCTAssertTrue(status.isExplicit)
        XCTAssertNil(status.betterInstalled, "no natural voice installed, so nothing to point at")
    }

    /// Downloading Ava after picking Karen: the pick still wins (explicit is
    /// explicit) but the status must say a better voice is sitting unused.
    func testBetterInstalledVoiceIsSurfacedAfterExplicitCompactPick() {
        let settings = makeSettings()
        settings.setDefaultVoice("karen", forLocale: "en-US")
        let status = VoiceQualityStatus(locale: "en-US", inventory: inventory([samantha, karen, ava]), settings: settings)
        XCTAssertEqual(status.voice, karen)
        XCTAssertEqual(status.betterInstalled, ava)
        XCTAssertFalse(status.isNatural)
    }

    /// Automatic always takes the best voice, so nothing is ever "better".
    func testAutomaticPicksPremiumWithNothingBetter() {
        let status = VoiceQualityStatus(locale: "en-US", inventory: inventory([samantha, tom, ava]), settings: makeSettings())
        XCTAssertEqual(status.voice, ava)
        XCTAssertTrue(status.isPremium)
        XCTAssertFalse(status.isExplicit)
        XCTAssertNil(status.betterInstalled)
    }

    /// An Enhanced pick with Premium installed is natural but improvable.
    func testEnhancedPickWithPremiumInstalled() {
        let settings = makeSettings()
        settings.setDefaultVoice("tom", forLocale: "en-US")
        let status = VoiceQualityStatus(locale: "en-US", inventory: inventory([samantha, tom, ava]), settings: settings)
        XCTAssertEqual(status.voice, tom)
        XCTAssertTrue(status.isNatural)
        XCTAssertEqual(status.betterInstalled, ava)
    }

    /// A deck's own voice outranks the Settings default.
    func testDeckOverrideOutranksSettingsDefault() {
        let settings = makeSettings()
        settings.setDefaultVoice("ava", forLocale: "en-US")
        let status = VoiceQualityStatus(locale: "en-US", inventory: inventory([samantha, tom, ava]), settings: settings, deckVoice: "tom")
        XCTAssertEqual(status.voice, tom)
        XCTAssertTrue(status.isExplicit)
        XCTAssertEqual(status.betterInstalled, ava)
    }

    /// A pick that was deleted from the device — or that speaks another
    /// language — is ignored, and Automatic takes over silently.
    func testUninstalledOrForeignPickFallsBackToAutomatic() {
        let settings = makeSettings()
        settings.setDefaultVoice("kyoko", forLocale: "en-US")
        let status = VoiceQualityStatus(locale: "en-US", inventory: inventory([samantha, kyoko]), settings: settings)
        XCTAssertEqual(status.voice, samantha)
        XCTAssertFalse(status.isExplicit)
    }

    func testSupertonicPickIsNaturalAndExplicit() {
        let settings = makeSettings()
        let f1 = VoiceCatalogVoice(identifier: "supertonic3:F1", name: "Female 1", language: "en-US", quality: .premium, kind: .supertonic3)
        settings.setDefaultVoice(f1.identifier, forLocale: "en-US")
        let status = VoiceQualityStatus(locale: "en-US", inventory: inventory([samantha, f1]), settings: settings)
        XCTAssertEqual(status.voice, f1)
        XCTAssertTrue(status.isExplicit)
        XCTAssertTrue(status.isNatural)
        XCTAssertTrue(status.isPremium)
        XCTAssertNil(status.betterInstalled)
        XCTAssertEqual(inventory([samantha, f1]).automaticVoice(for: "en-US"), samantha)
    }

    func testMissingLanguage() {
        let status = VoiceQualityStatus(locale: "fr-FR", inventory: inventory([samantha]), settings: makeSettings())
        XCTAssertNil(status.voice)
        XCTAssertFalse(status.isNatural)
        XCTAssertFalse(status.isExplicit)
    }

    // MARK: VoiceInventory helpers

    /// The picker's Automatic row must describe what Automatic would do,
    /// never echo the user's explicit choice back at them.
    func testAutomaticVoiceIgnoresExplicitChoice() {
        let settings = makeSettings()
        settings.setDefaultVoice("karen", forLocale: "en-US")
        let inv = inventory([samantha, karen, ava])
        XCTAssertEqual(inv.automaticVoice(for: "en-US"), ava)
        XCTAssertEqual(inv.chosenVoice(for: "en-US", settings: settings), karen)
        XCTAssertEqual(inv.effectiveVoice(for: "en-US", settings: settings), karen)
        XCTAssertEqual(inv.effectiveVoice(for: "en-US", settings: settings, override: "ava"), ava)
    }
}
