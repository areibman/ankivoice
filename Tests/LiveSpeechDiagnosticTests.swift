import XCTest

struct TestTimeoutError: Error { }
func testWithTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeoutError()
        }
        guard let result = try await group.next() else { throw TestTimeoutError() }
        group.cancelAll()
        return result
    }
}

/// True when running in the iOS simulator (speech recognition is unavailable).
var isSimulator: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}

import Speech
import AVFAudio
@testable import AnkiVoice

/// Runs the REAL Apple Speech framework APIs on this simulator/device and
/// reports exactly what's available. This test FAILS if speech recognition
/// is broken — proving whether the voice loop can work end-to-end.
///
/// This is NOT a mock — it queries the actual system state.
final class LiveSpeechDiagnosticTests: XCTestCase {

    /// Reports the actual SpeechTranscriber state on this device.
    /// If this test fails, speech recognition CANNOT work on this hardware.
    func testSpeechTranscriberAvailableOnThisDevice() async throws {
        let available = SpeechTranscriber.isAvailable
        print("[LIVE-DIAG] SpeechTranscriber.isAvailable = \(available)")
        if isSimulator { throw XCTSkip("Simulator does not support speech recognition") }
        XCTAssertTrue(available, "SpeechTranscriber is not available on this device — voice recognition cannot work")
    }

    /// Reports which locales are actually supported by the system.
    func testSupportedLocalesIncludeEnglish() async throws {
        let locales = await SpeechTranscriber.supportedLocales
        let identifiers = locales.map(\.identifier).sorted()
        print("[LIVE-DIAG] Supported locales (\(identifiers.count)): \(identifiers.joined(separator: ", "))")

        let enUS = Locale(identifier: "en-US")
        let match = await SpeechTranscriber.supportedLocale(equivalentTo: enUS)
        print("[LIVE-DIAG] en-US equivalent = \(match?.identifier ?? "NOT FOUND")")
        if isSimulator { throw XCTSkip("Simulator does not support speech recognition") }
        XCTAssertNotNil(match, "en-US is not a supported speech locale on this device")
    }

    /// Reports which locales have their ASSETS INSTALLED (models downloaded).
    /// This is the key test — if en-US assets aren't installed, recognition
    /// will fail with RecogRejected even though the locale is "supported".
    func testEnglishAssetsInstalled() async throws {
        let enUS = Locale(identifier: "en-US")
        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = installed.map(\.identifier).sorted()
        print("[LIVE-DIAG] Installed locales (\(installedIDs.count)): \(installedIDs.joined(separator: ", "))")

        let enInstalled = installed.contains { $0.identifier == "en-US" || $0.identifier.hasPrefix("en") }
        print("[LIVE-DIAG] English assets installed = \(enInstalled)")

        if !enInstalled {
            print("[LIVE-DIAG] WARNING: English assets NOT installed. Recognition WILL fail.")
            print("[LIVE-DIAG] On real device: Settings → General → Keyboard → Dictation to install.")
            print("[LIVE-DIAG] On simulator: may need to enable dictation in Settings.")
        }
        // This is informational — don't fail if not installed, just log it.
    }

    /// Reports the AssetInventory status for the en-US transcriber.
    func testAssetInventoryStatus() async throws {
        let enUS = Locale(identifier: "en-US")
        let probe = SpeechTranscriber(locale: enUS, preset: .transcription)
        let status = await AssetInventory.status(forModules: [probe])
        print("[LIVE-DIAG] AssetInventory.status = \(String(describing: status))")

        // .installed = ready to use
        // .supported = supported but assets not downloaded
        // .downloading = download in progress
        // .unsupported = not supported on this device
        if status != .installed {
            print("[LIVE-DIAG] Assets NOT installed — reserving locale first...")
            // CRITICAL: must reserve before any asset operations
            do {
                let reserved = try await AssetInventory.reserve(locale: enUS)
                print("[LIVE-DIAG] AssetInventory.reserve(en-US) = \(reserved)")
            } catch {
                print("[LIVE-DIAG] Reserve FAILED: \(error.localizedDescription)")
            }
            let postReserveStatus = await AssetInventory.status(forModules: [probe])
            print("[LIVE-DIAG] Status after reserve: \(String(describing: postReserveStatus))")
            if postReserveStatus != .installed {
                let request = try await AssetInventory.assetInstallationRequest(supporting: [probe])
                if let request {
                    print("[LIVE-DIAG] Got installation request, attempting download...")
                    do {
                        try await testWithTimeout(seconds: 30) {
                            try await request.downloadAndInstall()
                        }
                    } catch {
                        print("[LIVE-DIAG] Download failed (expected on simulator): \(error.localizedDescription)")
                    }
                    let newStatus = await AssetInventory.status(forModules: [probe])
                    print("[LIVE-DIAG] After download attempt: \(String(describing: newStatus))")
                } else {
                    print("[LIVE-DIAG] No installation request returned")
                }
            }
        }
    }

    /// Lists ALL TTS voices available for English with their quality levels.
    /// This tells us if premium/enhanced voices exist on this device.
    func testTTSVoicesAvailable() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }

        print("[LIVE-DIAG] English TTS voices (\(voices.count)):")
        for v in voices {
            let quality = v.quality == .premium ? "PREMIUM" :
                          v.quality == .enhanced ? "ENHANCED" : "compact"
            print("[LIVE-DIAG]   \(v.name) | \(v.language) | \(quality) | \(v.identifier)")
        }

        let hasEnhanced = voices.contains { $0.quality == .enhanced }
        let hasPremium = voices.contains { $0.quality == .premium }
        print("[LIVE-DIAG] Has enhanced: \(hasEnhanced), Has premium: \(hasPremium)")

        if !hasEnhanced && !hasPremium {
            print("[LIVE-DIAG] WARNING: Only compact voices — TTS will sound robotic.")
            print("[LIVE-DIAG] On real device: Settings → Accessibility → Spoken Content → Voices")
        }
    }

    /// Attempts to actually CREATE and START a SpeechAnalyzer with a
    /// SpeechDetector module. This exercises the exact code path that
    /// fails with "RecogRejected" on the user's device.
    func testSpeechAnalyzerCanStart() async throws {
        let detector = SpeechDetector()
        let enUS = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: enUS,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [detector, transcriber])

        // Create a silent audio buffer to feed it
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [detector, transcriber])
        print("[LIVE-DIAG] Best audio format: \(String(describing: format))")

        let stream = AsyncStream<AnalyzerInput> { continuation in
            // Feed one second of silence
            if let format {
                let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))
                silence?.frameLength = AVAudioFrameCount(format.sampleRate)
                continuation.yield(AnalyzerInput(buffer: silence!))
            }
            continuation.finish()
        }

        do {
            let result = try await testWithTimeout(seconds: 20) {
                try await analyzer.start(inputSequence: stream)
            }
            print("[LIVE-DIAG] Analyzer started successfully! Result: \(String(describing: result))")
        } catch let error as NSError {
            print("[LIVE-DIAG] Analyzer FAILED: domain=\(error.domain) code=\(error.code)")
            print("[LIVE-DIAG] Analyzer error: \(error.localizedDescription)")
            print("[LIVE-DIAG] UserInfo: \(error.userInfo)")

            // If the code is 11103 or -19241, assets aren't installed
            if error.code == 11_103 || error.code == -1_9241 {
                print("[LIVE-DIAG] CONFIRMED: RecogRejected due to missing assets")
            }
            // Don't fail the test — this is diagnostic
        } catch {
            print("[LIVE-DIAG] Analyzer threw non-NSError: \(error)")
        }
        await analyzer.cancelAndFinishNow()
    }

    /// Tests the full VoiceSelector with the REAL system voice catalog.
    func testRealVoiceSelector() throws {
        if isSimulator {
            let catalog = SystemVoiceCatalog()
            let voices = catalog.voices(matching: "en")
            if !voices.contains(where: { $0.quality != .compact }) {
                throw XCTSkip("Simulator only has compact voices — selector behavior verified in unit tests")
            }
        }
        let catalog = SystemVoiceCatalog()
        let englishVoices = catalog.voices(matching: "en")
        print("[LIVE-DIAG] Catalog returned \(englishVoices.count) English voices")

        let config = VoiceConfig(
            questionLocale: "en-US",
            answerLocale: "en-US",
            preferredQuality: .auto
        )
        let selector = TextToSpeech.VoiceSelector.best(
            localized: englishVoices,
            allVoices: catalog.voices(matching: ""),
            requestedLocale: "en-US",
            preferredQuality: config.preferredQuality
        )
        print("[LIVE-DIAG] VoiceSelector.best for en-US/auto = \(selector ?? "nil")")

        // Find the quality of the selected voice
        if let id = selector,
           let voice = englishVoices.first(where: { $0.identifier == id }) {
            print("[LIVE-DIAG] Selected voice quality: \(voice.quality)")
            XCTAssertNotEqual(voice.quality, .compact,
                "Selected a compact voice when auto should prefer higher quality. " +
                "Available: \(englishVoices.map { "\($0.name):\($0.quality)" })")
        }
    }
}

/// Timeout helper for async tests.

