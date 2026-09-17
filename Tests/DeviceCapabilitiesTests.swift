import XCTest
@testable import AnkiVoice
import Speech
import AVFAudio

/// In-memory device capabilities for deterministic tests of the diagnostic
/// surface. Real Apple frameworks are queried in LiveDeviceSpeechCapabilities.
final class StubCapabilities: DeviceSpeechCapabilitiesProtocol, @unchecked Sendable {
    var report: DeviceSpeechReport

    init(_ report: DeviceSpeechReport) {
        self.report = report
    }

    func report(commandLocale: String) async -> DeviceSpeechReport {
        // Override locale with whatever the caller asked for, but keep everything else.
        DeviceSpeechReport(
            commandLocale: commandLocale,
            speechRecognitionSupported: report.speechRecognitionSupported,
            speechAssetsInstalled: report.speechAssetsInstalled,
            ttsVoicesForLocale: report.ttsVoicesForLocale,
            highestAvailableTTSQuality: report.highestAvailableTTSQuality
        )
    }
}

/// Test the diagnostic that maps device state to actionable user messages.
/// These scenarios model what real iPhones do.
final class DeviceCapabilitiesDiagnosticTests: XCTestCase {

    // MARK: - RecogRejected root cause

    /// User's exact failure: assets not downloaded → AppStore recognizer
    /// silently fails with RecogRejected. The diagnostic must tell them
    /// to enable Dictation in Settings, which downloads the assets.
    func testMissingAssetsDirectsUserToEnableDictation() {
        let report = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: true,
            speechAssetsInstalled: false,
            ttsVoicesForLocale: [.init(identifier: "en-US-c", name: "Compact", language: "en-US", quality: .compact)],
            highestAvailableTTSQuality: .compact
        )
        let steps = report.nextSteps
        XCTAssertTrue(steps.contains { $0.contains("Settings") && $0.contains("Dictation") },
                      "Must instruct the user to enable Dictation in Settings; got: \(steps)")
        XCTAssertTrue(report.readyForVoiceLoop == false)
    }

    /// Speech recognition entirely unavailable on device (old hardware,
    /// restricted profile, etc.) → tell the user it's not the app.
    func testSpeechRecognitionUnsupportedSurfacesHonestMessage() {
        let report = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: false,
            speechAssetsInstalled: false,
            ttsVoicesForLocale: [],
            highestAvailableTTSQuality: nil
        )
        let steps = report.nextSteps
        XCTAssertTrue(steps.contains { $0.contains("Speech recognition isn't available") })
        XCTAssertTrue(report.readyForVoiceLoop == false)
    }

    /// Locale isn't supported by Apple Speech at all → must say so clearly.
    func testUnsupportedLocaleSurfacesClearMessage() {
        let report = DeviceSpeechReport(
            commandLocale: "xx-XX",
            speechRecognitionSupported: false,
            speechAssetsInstalled: false,
            ttsVoicesForLocale: [],
            highestAvailableTTSQuality: nil
        )
        XCTAssertTrue(report.nextSteps.contains { $0.contains("xx-XX") || $0.contains("available") })
    }

    /// Happy path: assets installed, locale supported, premium voice available.
    func testFullySetupDeviceHasNoActions() {
        let report = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: true,
            speechAssetsInstalled: true,
            ttsVoicesForLocale: [
                .init(identifier: "en-US-c", name: "Compact", language: "en-US", quality: .compact),
                .init(identifier: "en-US-e", name: "Samantha", language: "en-US", quality: .enhanced),
                .init(identifier: "en-US-p", name: "Ava", language: "en-US", quality: .premium),
            ],
            highestAvailableTTSQuality: .premium
        )
        XCTAssertTrue(report.nextSteps.isEmpty, "Fully-setup device should require no user action; got: \(report.nextSteps)")
        XCTAssertEqual(report.recommendedTTSVoiceIdentifier, "en-US-p")
        XCTAssertTrue(report.readyForVoiceLoop)
    }

    // MARK: - "Bad old voice" root cause

    /// The user's actual TTS problem: only compact voices installed. Must
    /// tell them exactly where to go to download a better voice.
    func testOnlyCompactVoicesInstalledDirectsUserToSpokenContent() {
        let report = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: true,
            speechAssetsInstalled: true,
            ttsVoicesForLocale: [
                .init(identifier: "en-US-c1", name: "Compact A", language: "en-US", quality: .compact),
                .init(identifier: "en-US-c2", name: "Compact B", language: "en-US", quality: .compact),
            ],
            highestAvailableTTSQuality: .compact
        )
        let steps = report.nextSteps
        XCTAssertTrue(steps.contains { $0.contains("Read & Speak") && $0.contains("robotic") })
        // The most common wrong turn: downloading a Siri voice, which apps can't use.
        XCTAssertTrue(steps.contains { $0.contains("Siri voices can't be used by apps") })
        XCTAssertFalse(steps.contains { $0.contains("download a Siri voice") })
        XCTAssertEqual(report.recommendedTTSVoiceIdentifier, "en-US-c1")
    }

    /// Only enhanced available → recommend premium via Read & Speak.
    func testOnlyEnhancedVoicesRecommendPremiumDownload() {
        let report = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: true,
            speechAssetsInstalled: true,
            ttsVoicesForLocale: [
                .init(identifier: "en-US-c", name: "Compact", language: "en-US", quality: .compact),
                .init(identifier: "en-US-e", name: "Samantha", language: "en-US", quality: .enhanced),
            ],
            highestAvailableTTSQuality: .enhanced
        )
        let steps = report.nextSteps
        XCTAssertTrue(steps.contains { $0.contains("Premium") })
        XCTAssertEqual(report.recommendedTTSVoiceIdentifier, "en-US-e")
    }

    /// Premium voice already installed → no action needed.
    func testPremiumVoiceInstalledHasNoSteps() {
        let report = DeviceSpeechReport(
            commandLocale: "en-US",
            speechRecognitionSupported: true,
            speechAssetsInstalled: true,
            ttsVoicesForLocale: [
                .init(identifier: "en-US-p", name: "Ava", language: "en-US", quality: .premium),
            ],
            highestAvailableTTSQuality: .premium
        )
        XCTAssertTrue(report.nextSteps.isEmpty)
        XCTAssertEqual(report.recommendedTTSVoiceIdentifier, "en-US-p")
    }

    // MARK: - Catalog protocol contract

    /// Voice catalog must respect language prefix.
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
}
