import XCTest
@testable import AnkiVoice

/// End-to-end session recovery tests: when recognition fails (e.g. RecogRejected
/// from missing assets), the session must surface a clear message AND stay usable
/// so the user isn't trapped. Mirrors the user-reported failure.
@MainActor
final class RecognitionRecoveryTests: XCTestCase {

    private var db: SQLiteDatabase!
    private var decks: DeckRepository!
    private var cardsRepo: CardRepository!
    private var reviewsRepo: ReviewRepository!
    private var queue: StudyQueue!
    private var settings: SettingsStore!
    private var controller: StudySessionController!

    override func setUp() async throws {
        db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        decks = DeckRepository(db: db)
        cardsRepo = CardRepository(db: db)
        reviewsRepo = ReviewRepository(db: db)
        queue = StudyQueue(cards: cardsRepo, reviews: reviewsRepo)
        let defaults = UserDefaults(suiteName: "RecognitionRecovery-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        controller = StudySessionController(
            decks: decks, cards: cardsRepo, reviews: reviewsRepo,
            queue: queue, settings: settings
        )
    }

    /// When recognition throws RecogRejected, the controller must surface
    /// the classifier's actionable message AND the user must still be able
    /// to use Reveal + rating buttons to proceed.
    func testRecogRejectedSurfacesMessageAndSessionRemainsUsable() async throws {
        final class RejectingEngine: VoiceSessionEngine, @unchecked Sendable {
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
                let locale = "en-US"
                // Simulate the RecogRejected failure at session start.
                let err = NSError(domain: "kAFAssistantErrorDomain", code: 11_103, userInfo: nil)
                continuation.yield(.failure(RecognitionErrorClassifier.message(for: err, locale: locale)))
            }
            func stopListening() {}
            func stopSpeaking() {}
            func shutdown() { continuation.finish() }
        }

        let deck = try decks.create(fullName: "Recovery")
        _ = try cardsRepo.createNote(fields: ["Q", "A"], deckID: deck.id)
        await controller.start(deck: deck, engine: RejectingEngine())

        // Wait for the session to attempt listening (and get the failure).
        try await Task.sleep(for: .milliseconds(300))

        // 1. The session surfaced a useful message, not a raw Apple error.
        XCTAssertNotNil(controller.statusMessage)
        XCTAssertTrue(
            controller.statusMessage?.contains("Voice recognition") ?? false
            || controller.statusMessage?.contains("assets") ?? false
            || controller.statusMessage?.contains("Settings") ?? false,
            "Expected actionable message; got: \(controller.statusMessage ?? "nil")"
        )

        // 2. The user is NOT stuck — Reveal and rating buttons must still work.
        try await Task.sleep(for: .milliseconds(50))
        await controller.reveal(mode: .touch)
        // Wait for rating phase.
        let deadline = Date().addingTimeInterval(2)
        while controller.state != .awaitingRating && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.state, .awaitingRating)

        await controller.rate(.good, mode: .touch)
        XCTAssertEqual(controller.reviewsThisSession, 1)
    }

    /// When recognition works, the controller must not silently swallow
    /// transcript events — the happy path must still produce rating results.
    func testHappyPathRecognitionStillWorks() async throws {
        let engine = MockVoiceEngine()
        let deck = try decks.create(fullName: "Happy")
        _ = try cardsRepo.createNote(fields: ["Q", "A"], deckID: deck.id)
        await controller.start(deck: deck, engine: engine)

        // Wait for the engine to start listening.
        let deadline = Date().addingTimeInterval(2)
        while controller.state != .awaitingAnswer && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.state, .awaitingAnswer)

        // Reveal → rate Good.
        engine.emitAnswerEnded()
        deadline.timeIntervalSince1970
        let d2 = Date().addingTimeInterval(2)
        while controller.state != .awaitingRating && Date() < d2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.state, .awaitingRating)
        engine.emitCommand(.good)

        let d3 = Date().addingTimeInterval(2)
        while controller.reviewsThisSession == 0 && Date() < d3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.reviewsThisSession, 1)
    }
}
