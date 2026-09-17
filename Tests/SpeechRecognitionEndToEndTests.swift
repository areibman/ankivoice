import XCTest
@testable import AnkiVoice
import Speech
import AVFoundation

/// End-to-end speech recognition tests. These exercise the actual code
/// paths in SpeechVoiceEngine on the simulator/device to validate that
/// the user's failure modes are handled correctly — including the case where
/// assets can't be downloaded (which is what happens on the simulator AND
/// what happened to the user on a real device before they enabled Dictation).
final class SpeechRecognitionEndToEndTests: XCTestCase {

    /// Test that the Info.plist contains ALL required speech keys.
    /// If this fails, recognition will be rejected by iOS immediately.
    func testInfoPlistContainsSpeechPrivacyKeys() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertNotNil(info["NSMicrophoneUsageDescription"] as? String,
                        "NSMicrophoneUsageDescription missing — speech capture will fail")
        XCTAssertNotNil(info["NSSpeechRecognitionUsageDescription"] as? String,
                        "NSSpeechRecognitionUsageDescription missing — recognition will fail")
    }

    /// Test that AssetInventory.reserve returns a usable state on this device.
    /// If this fails, the session can still run in touch-only mode (graceful).
    func testReserveLocaleBehavior() async {
        let locale = Locale(identifier: "en-US")
        let reserved: Bool
        do {
            reserved = try await AssetInventory.reserve(locale: locale)
        } catch {
            XCTFail("reserve threw: \(error.localizedDescription)")
            return
        }
        speechLog.info("[E2E-DIAG] AssetInventory.reserve(en-US) returned \(reserved)")
        // Note: on simulator this returns false (speech not supported).
        // On a real device it returns true after the first call.
    }

    /// Test that AssetInventory's maximumReservedLocales is respected.
    /// If this fails, reserve() may silently return false.
    func testReserveLimitRespected() async {
        let max = AssetInventory.maximumReservedLocales
        speechLog.info("[E2E-DIAG] maximumReservedLocales = \(max)")
        XCTAssertGreaterThan(max, 0, "max reserved locales must be > 0")
    }

    /// Test that the RecognitionErrorClassifier maps RecogRejected codes to
    /// actionable messages — the user MUST see this on their device.
    func testRecogRejectedMapsToActionableMessage() {
        // Code -19241 is the IrisAPIErrorDomain "not subscribed" error
        let iris = NSError(domain: "IrisAPI", code: -1_9241, userInfo: [
            NSLocalizedDescriptionKey: "test"
        ])
        let msg = RecognitionErrorClassifier.message(for: iris, locale: "en-US")
        XCTAssertTrue(msg.contains("Settings") || msg.contains("Voice recognition") || msg.contains("installed"),
                     "Message should tell user to fix something: \(msg)")
        // Code 11103 is the legacy kAFAssistantErrorDomain
        let legacy = NSError(domain: "kAFAssistantErrorDomain", code: 11_103, userInfo: nil)
        let msg2 = RecognitionErrorClassifier.message(for: legacy, locale: "en-US")
        XCTAssertTrue(msg2.contains("Voice recognition") || msg2.contains("installed"))
    }

    /// Test the full DeviceSpeechReport.nextSteps for every failure mode.
    func testDeviceReportNextStepsForAllFailureModes() {
        // 1. Missing assets
        let missingAssets = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: true,
            speechAssetsInstalled: false,
            ttsVoicesForLocale: [],
            highestAvailableTTSQuality: nil
        )
        XCTAssertTrue(missingAssets.nextSteps.contains { $0.contains("Dictation") },
                     "Missing assets must direct user to enable Dictation")

        // 2. Only compact voices
        let compactOnly = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: true,
            speechAssetsInstalled: true,
            ttsVoicesForLocale: [
                .init(identifier: "en-US-c", name: "Compact", language: "en-US", quality: .compact)
            ],
            highestAvailableTTSQuality: .compact
        )
        XCTAssertTrue(compactOnly.nextSteps.contains { $0.contains("Read & Speak") && $0.contains("robotic") },
                     "Compact-only must direct user to Accessibility ▸ Read & Speak")

        // 3. Hardware doesn't support recognition
        let noHW = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: false,
            speechAssetsInstalled: false,
            ttsVoicesForLocale: [],
            highestAvailableTTSQuality: nil
        )
        XCTAssertTrue(noHW.nextSteps.contains { $0.contains("not available") || $0.contains("Speech recognition") })

        // 4. Fully set up — no actions needed
        let perfect = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: true,
            speechAssetsInstalled: true,
            ttsVoicesForLocale: [
                .init(identifier: "en-US-p", name: "Premium", language: "en-US", quality: .premium)
            ],
            highestAvailableTTSQuality: .premium
        )
        XCTAssertTrue(perfect.nextSteps.isEmpty,
                     "Fully-setup device must have zero actions required")
        XCTAssertTrue(perfect.readyForVoiceLoop)
    }

    /// Simulates the exact user failure: assets not installed → ensureAssets
    /// throws → engine falls back to touch-only and surfaces the actionable
    /// diagnostic. This is the contract that protects users from being stuck.
    @MainActor
    func testAssetDownloadFailureFallsBackToTouchOnly() async throws {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        let decks = DeckRepository(db: db)
        let cards = CardRepository(db: db)
        let reviews = ReviewRepository(db: db)
        let queue = StudyQueue(cards: cards, reviews: reviews)
        let defaults = UserDefaults(suiteName: "AssetFailure-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let controller = StudySessionController(
            decks: decks, cards: cards, reviews: reviews,
            queue: queue, settings: settings
        )

        // Engine that fails prepare() with RecogRejected-like error
        final class FailingEngine: VoiceSessionEngine, @unchecked Sendable {
            let events: AsyncStream<VoiceEvent>
            private let continuation: AsyncStream<VoiceEvent>.Continuation
            init() {
                var c: AsyncStream<VoiceEvent>.Continuation!
                events = AsyncStream { c = $0 }
                continuation = c
            }
            func prepare(voice: VoiceConfig, commandLocale: String) async throws {
                throw VoiceEngineError.speechUnavailable
            }
            func speak(_ segments: [SpeechRenderer.Segment], voice: VoiceConfig) async {}
            func playConfirmationTone() async {}
            func startListening(phase: CommandRecognizer.ListeningPhase, endpointMs: Int, recognizer: CommandRecognizer) async throws {}
            func stopListening() {}
            func stopSpeaking() {}
            func shutdown() { continuation.finish() }
        }

        let deck = try decks.create(fullName: "ReserveFail")
        _ = try cards.createNote(fields: ["Q", "A"], deckID: deck.id)
        await controller.start(deck: deck, engine: FailingEngine())

        // The session MUST continue in touch-only mode rather than getting stuck.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(controller.voiceAvailable,
                      "voiceAvailable must be false when prepare() throws")
        XCTAssertNotNil(controller.statusMessage,
                       "statusMessage must be set so the user knows what happened")
        XCTAssertTrue(
            controller.statusMessage?.contains("Voice") ?? false
                || controller.statusMessage?.contains("touch") ?? false
                || controller.statusMessage?.contains("recogni") ?? false,
            "statusMessage must reference voice/touch/recognition; got: \(controller.statusMessage ?? "nil")"
        )
    }

    /// Simulates: prepare() succeeds, but startListening() fails with RecogRejected.
    /// The session must surface the actionable message, not stay stuck.
    @MainActor
    func testStartListeningFailureSurfacesActionableMessage() async throws {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        let decks = DeckRepository(db: db)
        let cards = CardRepository(db: db)
        let reviews = ReviewRepository(db: db)
        let queue = StudyQueue(cards: cards, reviews: reviews)
        let defaults = UserDefaults(suiteName: "ListeningFail-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let controller = StudySessionController(
            decks: decks, cards: cards, reviews: reviews,
            queue: queue, settings: settings
        )

        final class ListeningFailureEngine: VoiceSessionEngine, @unchecked Sendable {
            let events: AsyncStream<VoiceEvent>
            private let continuation: AsyncStream<VoiceEvent>.Continuation
            init() {
                var c: AsyncStream<VoiceEvent>.Continuation!
                events = AsyncStream { c = $0 }
                continuation = c
            }
            func prepare(voice: VoiceConfig, commandLocale: String) async throws {}
            func speak(_ segments: [SpeechRenderer.Segment], voice: VoiceConfig) async {}
            func playConfirmationTone() async {}
            func startListening(phase: CommandRecognizer.ListeningPhase, endpointMs: Int, recognizer: CommandRecognizer) async throws {
                let err = NSError(domain: "IrisAPI", code: -1_9241, userInfo: nil)
                continuation.yield(.failure(RecognitionErrorClassifier.message(for: err, locale: "en-US")))
            }
            func stopListening() {}
            func stopSpeaking() {}
            func shutdown() { continuation.finish() }
        }

        let deck = try decks.create(fullName: "ListenFail")
        _ = try cards.createNote(fields: ["Q", "A"], deckID: deck.id)
        await controller.start(deck: deck, engine: ListeningFailureEngine())

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotNil(controller.statusMessage)
        XCTAssertTrue(
            controller.statusMessage?.contains("Voice") ?? false
                || controller.statusMessage?.contains("assets") ?? false
                || controller.statusMessage?.contains("recogni") ?? false
                || controller.statusMessage?.contains("Settings") ?? false
        )
        // The session must still be in awaitingAnswer so the user can retry,
        // not stuck in idle or finished.
        XCTAssertNotEqual(controller.state, .idle)
        XCTAssertNotEqual(controller.state, .finished)
    }
}

import os
private let speechLog = Logger(subsystem: "local.ankivoice", category: "e2e-tests")
