import XCTest
import AVFAudio
import Speech
@testable import AnkiVoice

/// Hands-free study has to keep working with the screen locked or another app
/// in front. That rests on two things: the `audio` background mode, and a
/// microphone tap that runs for the whole session instead of being torn down
/// and rebuilt between every question, answer and rating. These guard both.
final class BackgroundAudioTests: XCTestCase {

    private func buffer(frames: AVAudioFrameCount = 512) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }

    /// Without this the system suspends the app the moment the screen locks,
    /// and recognition dies with it.
    func testAudioBackgroundModeIsDeclared() throws {
        let modes = try XCTUnwrap(Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("audio"), "UIBackgroundModes must contain audio; got \(modes)")
    }

    // MARK: - Tap sink

    /// Half-duplex without stopping capture: while the app speaks, the sink is
    /// detached and buffers are discarded rather than reaching the recognizer.
    func testDetachedSinkDropsBuffersInsteadOfRecognizingThem() throws {
        let sink = AudioTapSink()
        XCTAssertFalse(sink.isAttached)

        let buffer = try buffer()
        for _ in 0..<5 { sink.append(buffer) }

        XCTAssertEqual(sink.droppedBuffers, 5, "audio captured while speaking must be dropped")
    }

    func testAttachedSinkForwardsBuffers() throws {
        let sink = AudioTapSink()
        let request = SFSpeechAudioBufferRecognitionRequest()
        sink.attach(request)
        XCTAssertTrue(sink.isAttached)

        let buffer = try buffer()
        for _ in 0..<5 { sink.append(buffer) }
        request.endAudio()

        XCTAssertEqual(sink.droppedBuffers, 0, "buffers must reach the open recognition window")
    }

    /// A listening window ending mid-buffer is the normal case, not an error:
    /// the tap keeps running so the next window starts instantly.
    func testDetachingMidStreamStopsForwardingWithoutTearingDownCapture() throws {
        let sink = AudioTapSink()
        let request = SFSpeechAudioBufferRecognitionRequest()
        let buffer = try buffer()

        sink.attach(request)
        sink.append(buffer)
        XCTAssertEqual(sink.droppedBuffers, 0)

        sink.attach(nil)
        request.endAudio()
        sink.append(buffer)
        sink.append(buffer)

        XCTAssertFalse(sink.isAttached)
        XCTAssertEqual(sink.droppedBuffers, 2)
    }

    /// The tap runs on the audio render thread while the main actor swaps
    /// requests between phases. Appending must never touch a half-swapped
    /// reference or block on the writer.
    func testSinkToleratesConcurrentAppendAndAttach() throws {
        let sink = AudioTapSink()
        let buffer = try buffer()
        let requests = (0..<8).map { _ in SFSpeechAudioBufferRecognitionRequest() }

        let appends = expectation(description: "appends")
        appends.expectedFulfillmentCount = 200
        let swaps = expectation(description: "swaps")
        swaps.expectedFulfillmentCount = 100

        let render = DispatchQueue(label: "render")
        let control = DispatchQueue(label: "control")
        for _ in 0..<200 {
            render.async {
                sink.append(buffer)
                appends.fulfill()
            }
        }
        for i in 0..<100 {
            control.async {
                sink.attach(i.isMultiple(of: 3) ? nil : requests[i % requests.count])
                swaps.fulfill()
            }
        }

        wait(for: [appends, swaps], timeout: 10)
        sink.attach(nil)
        requests.forEach { $0.endAudio() }
    }
}

/// On-device recognition drops one-word utterances unless the engine notices
/// the speech itself and closes the request. These lock that decision.
final class ShortUtteranceTests: XCTestCase {

    func testWordThenQuietCountsAsAnEndedUtterance() throws {
        var meter = UtteranceEnergyMeter()
        for _ in 0..<10 { meter.observe(rms: 0.05, duration: 0.02) } // 200 ms
        meter.observe(rms: 0.001, duration: 0.6)
        let trailing = try XCTUnwrap(meter.trailingSilence)
        XCTAssertEqual(trailing, 0.6, accuracy: 0.001)
    }

    func testAClickIsNotSpeech() {
        var meter = UtteranceEnergyMeter()
        meter.observe(rms: 0.4, duration: 0.02)
        meter.observe(rms: 0.001, duration: 0.6)
        XCTAssertNil(meter.trailingSilence)
    }

    func testOngoingSpeechDoesNotCountAsSilence() {
        var meter = UtteranceEnergyMeter()
        for _ in 0..<10 { meter.observe(rms: 0.05, duration: 0.02) }
        meter.observe(rms: 0.001, duration: 0.2)
        for _ in 0..<5 { meter.observe(rms: 0.05, duration: 0.02) }
        XCTAssertNil(meter.trailingSilence, "a pause inside a phrase must not end it")
    }

    func testRoomToneDoesNotCountAsSpeech() {
        var meter = UtteranceEnergyMeter()
        for _ in 0..<100 { meter.observe(rms: 0.003, duration: 0.02) }
        XCTAssertNil(meter.trailingSilence)
    }

    func testLoudBufferThenSilenceEndsTheUtterance() throws {
        let meter = UtteranceEnergyMonitor()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let loud = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200))
        loud.frameLength = 3200 // 200 ms
        let samples = loud.floatChannelData![0]
        for index in 0..<3200 {
            samples[index] = sin(Float(index) * 0.4) * 0.25
        }
        meter.observe(loud)

        let quiet = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600))
        quiet.frameLength = 9600 // 600 ms
        for index in 0..<9600 { quiet.floatChannelData![0][index] = 0 }
        meter.observe(quiet)

        let trailing = try XCTUnwrap(meter.trailingSilence())
        XCTAssertGreaterThanOrEqual(trailing, SpeechVoiceEngine.shortUtteranceSilence)
    }

    func testShortCommandsCloseBeforeTheModelDiscardsThem() {
        XCTAssertEqual(
            SpeechVoiceEngine.unreportedSpeechSilence(phase: .awaitingRating, endpointMs: 2000),
            SpeechVoiceEngine.shortUtteranceSilence
        )
        XCTAssertEqual(
            SpeechVoiceEngine.unreportedSpeechSilence(phase: .paused, endpointMs: 2500),
            SpeechVoiceEngine.shortUtteranceSilence
        )
        XCTAssertEqual(
            SpeechVoiceEngine.unreportedSpeechSilence(phase: .awaitingAnswer, endpointMs: 900),
            0.9,
            accuracy: 0.001
        )
    }

    func testTaskHintPrefersShortPhrasesOverDictation() {
        XCTAssertEqual(SpeechVoiceEngine.recognitionTaskHint(for: .awaitingAnswer), .search)
        XCTAssertEqual(SpeechVoiceEngine.recognitionTaskHint(for: .awaitingRating), .confirmation)
        XCTAssertEqual(SpeechVoiceEngine.recognitionTaskHint(for: .paused), .confirmation)
    }

    func testForceFinalizeOnlyForUntranscribedSpeech() {
        let required = SpeechVoiceEngine.shortUtteranceSilence
        XCTAssertFalse(SpeechVoiceEngine.shouldForceFinalize(
            hasTranscript: false, alreadyFinalizing: false, trailingSilence: nil, silenceRequired: required
        ))
        XCTAssertFalse(SpeechVoiceEngine.shouldForceFinalize(
            hasTranscript: false, alreadyFinalizing: false, trailingSilence: 0.2, silenceRequired: required
        ))
        XCTAssertFalse(SpeechVoiceEngine.shouldForceFinalize(
            hasTranscript: true, alreadyFinalizing: false, trailingSilence: 1, silenceRequired: required
        ))
        XCTAssertFalse(SpeechVoiceEngine.shouldForceFinalize(
            hasTranscript: false, alreadyFinalizing: true, trailingSilence: 1, silenceRequired: required
        ))
        XCTAssertTrue(SpeechVoiceEngine.shouldForceFinalize(
            hasTranscript: false, alreadyFinalizing: false, trailingSilence: required, silenceRequired: required
        ))
    }
}
