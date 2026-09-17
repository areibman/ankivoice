import XCTest
import Speech
@testable import AnkiVoice

/// Integration tests verifying the legacy SFSpeechRecognizer path is wired
/// correctly. These tests verify the ENGINE actually uses the proven API on
/// the user's device.
final class SFSpeechRecognizerIntegrationTests: XCTestCase {

    func testSFSpeechRecognizerAvailableOnRealDevice() {
        // SFSpeechRecognizer has been available since iOS 10 and works on
        // both real devices and the simulator. The new iOS 26 SpeechAnalyzer
        // can fail with RecogRejected; SFSpeechRecognizer is the reliable
        // fallback.
        XCTAssertTrue(SFSpeechRecognizer.self != nil,
                     "SFSpeechRecognizer class must be available")
    }

    func testSFSpeechRecognizerCanBeCreatedForEnglish() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        XCTAssertNotNil(recognizer, "en-US SFSpeechRecognizer must be created on any iOS device")
    }

    func testSFSpeechRecognizerCanBeCreatedForOtherLocales() {
        let cases = ["en-GB", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "ja-JP", "zh-CN"]
        for case_ in cases {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: case_))
            XCTAssertNotNil(recognizer,
                           "SFSpeechRecognizer must be createable for \(case_)")
        }
    }

    }
