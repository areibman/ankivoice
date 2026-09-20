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
