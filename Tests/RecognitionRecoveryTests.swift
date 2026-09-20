import XCTest
@testable import AnkiVoice

/// When recognition fails — speech model missing, RecogRejected, no Dictation —
/// the session must say something actionable AND stay usable by touch, so the
/// user is never trapped.
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

    @discardableResult
    private func startSession(named name: String, engine: MockVoiceEngine) async throws -> Deck {
        let deck = try decks.create(fullName: name)
        _ = try cardsRepo.createNote(fields: ["Q", "A"], deckID: deck.id)
        await controller.start(deck: deck, engine: engine)
        return deck
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// `prepare()` throws (no on-device model): the session must continue in
    /// touch-only mode with a message, not stop.
    func testPrepareFailureFallsBackToTouchOnly() async throws {
        let engine = MockVoiceEngine()
        engine.prepareError = VoiceEngineError.onDeviceUnavailable("en-US")
        let deck = try await startSession(named: "PrepareFail", engine: engine)
        try await waitUntil(controller.state == .awaitingAnswer)

        XCTAssertFalse(controller.voiceAvailable, "voiceAvailable must be false when prepare() throws")
        let message = try XCTUnwrap(controller.statusMessage)
        XCTAssertTrue(message.contains("touch-only"), message)
        XCTAssertTrue(message.contains("Dictation"), "must tell the user how to fix it: \(message)")

        await controller.reveal(mode: .touch)
        try await waitUntil(controller.state == .awaitingRating)
        await controller.rate(.good, mode: .touch)
        XCTAssertEqual(controller.reviewsThisSession, 1)
        let card = try XCTUnwrap(try cardsRepo.cards(inDeck: deck.id).first)
        XCTAssertEqual(card.scheduling.kind, .learning, "touch ratings must still be scheduled")
    }

    /// `prepare()` succeeds but listening fails with RecogRejected: the
    /// classifier's message is shown and the card stays open for retry/touch.
    func testListeningFailureSurfacesMessageAndSessionRemainsUsable() async throws {
        let engine = MockVoiceEngine()
        let error = NSError(domain: "kAFAssistantErrorDomain", code: 11_103, userInfo: nil)
        engine.listeningFailure = RecognitionErrorClassifier.message(for: error, locale: "en-US")
        try await startSession(named: "ListenFail", engine: engine)
        try await waitUntil(controller.statusMessage != nil)

        let message = try XCTUnwrap(controller.statusMessage)
        XCTAssertTrue(message.contains("Voice recognition"), "expected the classifier's message; got: \(message)")
        XCTAssertTrue(message.contains("Dictation"), message)
        XCTAssertEqual(controller.state, .awaitingAnswer, "must stay on the card, not end the session")

        await controller.reveal(mode: .touch)
        try await waitUntil(controller.state == .awaitingRating)
        XCTAssertEqual(controller.state, .awaitingRating)
        await controller.rate(.good, mode: .touch)
        XCTAssertEqual(controller.reviewsThisSession, 1)
    }

    /// Happy path: transcript events are not swallowed and a spoken rating lands.
    func testHappyPathRecognitionStillWorks() async throws {
        let engine = MockVoiceEngine()
        try await startSession(named: "Happy", engine: engine)
        try await waitUntil(controller.state == .awaitingAnswer)
        XCTAssertEqual(controller.state, .awaitingAnswer)

        engine.emitAnswerEnded()
        try await waitUntil(controller.state == .awaitingRating)
        XCTAssertEqual(controller.state, .awaitingRating)

        engine.emitCommand(.good)
        try await waitUntil(controller.reviewsThisSession == 1)
        XCTAssertEqual(controller.reviewsThisSession, 1)
    }

    /// Without these keys iOS rejects capture/recognition outright.
    func testInfoPlistContainsSpeechPrivacyKeys() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertNotNil(info["NSMicrophoneUsageDescription"] as? String, "NSMicrophoneUsageDescription missing")
        XCTAssertNotNil(info["NSSpeechRecognitionUsageDescription"] as? String, "NSSpeechRecognitionUsageDescription missing")
    }
}

/// Apple's recognition errors must become instructions, never raw codes.
final class RecognitionErrorClassifierTests: XCTestCase {

    private func message(domain: String, code: Int, locale: String = "en-US", description: String? = nil) -> String {
        let userInfo = description.map { [NSLocalizedDescriptionKey: $0] }
        return RecognitionErrorClassifier.message(for: NSError(domain: domain, code: code, userInfo: userInfo), locale: locale)
    }

    /// RecogRejected (legacy 11103 and IrisAPI -19241): the on-device model is
    /// missing; the fix is turning on Dictation.
    func testRecogRejectedDirectsToDictation() {
        for (domain, code) in [("kAFAssistantErrorDomain", 11_103), ("IrisAPIErrorDomain", -1_9241)] {
            let msg = message(domain: domain, code: code, locale: "ja-JP")
            XCTAssertTrue(msg.contains("Dictation"), msg)
            XCTAssertTrue(msg.contains("ja-JP"), msg)
        }
    }

    func testUnavailableAndBusy() {
        XCTAssertTrue(message(domain: "kAFAssistantErrorDomain", code: 11_100).contains("not available"))
        XCTAssertTrue(message(domain: "kAFAssistantErrorDomain", code: 11_101).contains("busy"))
    }

    func testUnknownErrorKeepsSystemDescription() {
        let msg = message(domain: "CustomDomain", code: 99_999, description: "Something specific went wrong.")
        XCTAssertTrue(msg.contains("Something specific went wrong"), msg)
    }
}
