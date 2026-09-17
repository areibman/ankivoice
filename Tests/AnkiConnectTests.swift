import XCTest
@testable import AnkiVoice

/// Serves canned AnkiConnect replies keyed by `action`, so the client and
/// importer can be exercised without a running Anki.
final class AnkiConnectStubProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var requests: [[String: Any]] = []
    nonisolated(unsafe) static var lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responses = [:]
        requests = []
    }

    static func stub(_ action: String, _ body: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        responses[action] = (status, body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        } ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        let action = json["action"] as? String ?? ""

        Self.lock.lock()
        Self.requests.append(json)
        let stub = Self.responses[action]
        Self.lock.unlock()

        let (status, body) = stub ?? (500, #"{"result": null, "error": "unsupported action: \#(action)"}"#)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AnkiConnectClientTests: XCTestCase {

    private func makeClient() throws -> AnkiConnectClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnkiConnectStubProtocol.self]
        let session = URLSession(configuration: config)
        return try XCTUnwrap(AnkiConnectClient(host: "192.168.1.20", apiKey: "secret", session: session))
    }

    override func setUp() {
        super.setUp()
        AnkiConnectStubProtocol.reset()
    }

    func testEndpointParsing() {
        XCTAssertEqual(AnkiConnectClient.endpoint(host: "192.168.1.5", port: 8765)?.absoluteString, "http://192.168.1.5:8765/")
        XCTAssertEqual(AnkiConnectClient.endpoint(host: " mac-mini.local ", port: 8765)?.absoluteString, "http://mac-mini.local:8765/")
        XCTAssertEqual(AnkiConnectClient.endpoint(host: "192.168.1.5:9000", port: 8765)?.absoluteString, "http://192.168.1.5:9000/")
        XCTAssertEqual(AnkiConnectClient.endpoint(host: "http://mac.local:9000/some/path", port: 8765)?.absoluteString, "http://mac.local:9000/")
        XCTAssertEqual(AnkiConnectClient.endpoint(host: "https://anki.example.com", port: 8765)?.absoluteString, "https://anki.example.com:8765/")
        XCTAssertEqual(AnkiConnectClient.endpoint(host: "192.168.1.5/", port: 8765)?.absoluteString, "http://192.168.1.5:8765/")
        XCTAssertNil(AnkiConnectClient.endpoint(host: "   ", port: 8765))
        XCTAssertNil(AnkiConnectClient(host: ""))
    }

    func testPingSendsVersionAndKey() async throws {
        AnkiConnectStubProtocol.stub("version", #"{"result": 6, "error": null}"#)
        let client = try makeClient()
        let version = try await client.ping()
        XCTAssertEqual(version, 6)

        let request = try XCTUnwrap(AnkiConnectStubProtocol.requests.first)
        XCTAssertEqual(request["action"] as? String, "version")
        XCTAssertEqual(request["version"] as? Int, 6)
        XCTAssertEqual(request["key"] as? String, "secret")
    }

    func testOldVersionIsRejected() async throws {
        AnkiConnectStubProtocol.stub("version", #"{"result": 4, "error": null}"#)
        let client = try makeClient()
        do {
            _ = try await client.ping()
            XCTFail("expected unsupportedVersion")
        } catch let error as AnkiConnectClient.ClientError {
            XCTAssertEqual(error, .unsupportedVersion(4))
        }
    }

    func testAPIErrorSurfacesMessage() async throws {
        AnkiConnectStubProtocol.stub("deckNamesAndIds", #"{"result": null, "error": "valid api key must be provided"}"#)
        let client = try makeClient()
        do {
            _ = try await client.deckNamesAndIDs()
            XCTFail("expected apiError")
        } catch let error as AnkiConnectClient.ClientError {
            XCTAssertEqual(error, .apiError("valid api key must be provided"))
            XCTAssertTrue(error.localizedDescription.contains("API key"))
        }
    }

    func testNonJSONReplyIsBadResponse() async throws {
        AnkiConnectStubProtocol.stub("version", "<html>not anki</html>")
        let client = try makeClient()
        do {
            _ = try await client.ping()
            XCTFail("expected badResponse")
        } catch let error as AnkiConnectClient.ClientError {
            XCTAssertEqual(error, .badResponse)
        }
    }

    func testDeckStatsAreSortedByName() async throws {
        AnkiConnectStubProtocol.stub("getDeckStats", """
        {"result": {
            "1651445861967": {"deck_id": 1651445861967, "name": "Japanese::Verbs", "new_count": 20, "learn_count": 0, "review_count": 5, "total_in_deck": 1200},
            "1651445861960": {"deck_id": 1651445861960, "name": "Anatomy", "new_count": 0, "learn_count": 1, "review_count": 0, "total_in_deck": 40}
        }, "error": null}
        """)
        let client = try makeClient()
        let stats = try await client.deckStats(names: ["Japanese::Verbs", "Anatomy"])
        XCTAssertEqual(stats.map(\.name), ["Anatomy", "Japanese::Verbs"])
        XCTAssertEqual(stats.last?.totalInDeck, 1200)
        XCTAssertEqual(stats.last?.deckID, 1_651_445_861_967)
    }

    func testReviewsOfCardsKeyedByCardID() async throws {
        AnkiConnectStubProtocol.stub("getReviewsOfCards", """
        {"result": {"1653613948202": [
            {"id": 1653772912146, "usn": 1750, "ease": 1, "ivl": -20, "lastIvl": -20, "factor": 0, "time": 4000, "type": 0},
            {"id": 1653772500000, "usn": 1750, "ease": 3, "ivl": -600, "lastIvl": -20, "factor": 0, "time": 3000, "type": 0}
        ]}, "error": null}
        """)
        let client = try makeClient()
        let reviews = try await client.reviewsOfCards(ids: [1_653_613_948_202])
        let entries = try XCTUnwrap(reviews[1_653_613_948_202])
        XCTAssertEqual(entries.map(\.id), [1_653_772_500_000, 1_653_772_912_146], "sorted oldest first")
        let sent = try XCTUnwrap(AnkiConnectStubProtocol.requests.first?["params"] as? [String: Any])
        XCTAssertEqual(sent["cards"] as? [String], ["1653613948202"], "ids are sent as strings, as AnkiConnect expects")
    }

    func testRetrieveMediaFileHandlesMissing() async throws {
        AnkiConnectStubProtocol.stub("retrieveMediaFile", #"{"result": false, "error": null}"#)
        let client = try makeClient()
        let missing = try await client.retrieveMediaFile(named: "nope.mp3")
        XCTAssertNil(missing)

        AnkiConnectStubProtocol.stub("retrieveMediaFile", #"{"result": "\#(Data("hi".utf8).base64EncodedString())", "error": null}"#)
        let found = try await client.retrieveMediaFile(named: "hi.mp3")
        XCTAssertEqual(found, Data("hi".utf8))
    }
}

/// Thread-safe collector for progress callbacks fired off the test's actor.
private final class ProgressLog: @unchecked Sendable {
    private var stages: [AnkiConnectImporter.Progress.Stage] = []
    private let lock = NSLock()

    func record(_ stage: AnkiConnectImporter.Progress.Stage) {
        lock.lock(); defer { lock.unlock() }
        stages.append(stage)
    }

    var all: [AnkiConnectImporter.Progress.Stage] {
        lock.lock(); defer { lock.unlock() }
        return stages
    }
}

final class AnkiConnectImporterTests: XCTestCase {

    private func makeStores() throws -> (SQLiteDatabase, DeckRepository, CardRepository, ReviewRepository) {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        return (db, DeckRepository(db: db), CardRepository(db: db), ReviewRepository(db: db))
    }

    private func makeClient() throws -> AnkiConnectClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnkiConnectStubProtocol.self]
        return try XCTUnwrap(AnkiConnectClient(host: "127.0.0.1", session: URLSession(configuration: config)))
    }

    override func setUp() {
        super.setUp()
        AnkiConnectStubProtocol.reset()
        AnkiConnectStubProtocol.stub("version", #"{"result": 6, "error": null}"#)
        AnkiConnectStubProtocol.stub("findCards", #"{"result": [2001, 2002, 2003], "error": null}"#)
        AnkiConnectStubProtocol.stub("cardsInfo", """
        {"result": [
            {"cardId": 2001, "note": 1001, "deckName": "Japanese::Vocabulary", "modelName": "Japanese Vocab", "ord": 0,
             "type": 2, "queue": 2, "due": 1200, "interval": 30, "reps": 4, "lapses": 0, "mod": 1700000000},
            {"cardId": 2002, "note": 1001, "deckName": "Japanese::Vocabulary", "modelName": "Japanese Vocab", "ord": 1,
             "type": 0, "queue": 0, "due": 1, "interval": 0, "reps": 0, "lapses": 0, "mod": 1700000000},
            {"cardId": 2003, "note": 1002, "deckName": "Japanese", "modelName": "Cloze Facts", "ord": 0,
             "type": 2, "queue": -1, "due": 5, "interval": 5, "reps": 2, "lapses": 1, "mod": 1700000000}
        ], "error": null}
        """)
        AnkiConnectStubProtocol.stub("notesInfo", """
        {"result": [
            {"noteId": 1001, "modelName": "Japanese Vocab", "tags": ["core", "vocab"], "mod": 1700000000, "cards": [2001, 2002],
             "fields": {"Back": {"value": "to eat[sound:taberu.mp3]", "order": 1}, "Front": {"value": "食べる", "order": 0}}},
            {"noteId": 1002, "modelName": "Cloze Facts", "tags": [], "mod": 1700000000, "cards": [2003],
             "fields": {"Text": {"value": "Tokyo is the capital of {{c1::Japan}}.", "order": 0}}}
        ], "error": null}
        """)
        AnkiConnectStubProtocol.stub("getReviewsOfCards", """
        {"result": {"2001": [
            {"id": 1600000001000, "usn": 1, "ease": 3, "ivl": 1, "lastIvl": 0, "factor": 0, "time": 3000, "type": 0},
            {"id": 1600086400000, "usn": 1, "ease": 3, "ivl": 3, "lastIvl": 1, "factor": 2500, "time": 2500, "type": 1},
            {"id": 1600090000000, "usn": 1, "ease": 0, "ivl": 3, "lastIvl": 3, "factor": 2500, "time": 0, "type": 4}
        ]}, "error": null}
        """)
        AnkiConnectStubProtocol.stub("findModelsByName", """
        {"result": [
            {"id": 3001, "name": "Japanese Vocab", "type": 0,
             "flds": [{"name": "Front", "ord": 0}, {"name": "Back", "ord": 1}],
             "tmpls": [{"name": "Recognition", "ord": 0, "qfmt": "{{Front}}", "afmt": "{{FrontSide}}<hr id=answer>{{Back}}"},
                       {"name": "Production", "ord": 1, "qfmt": "{{Back}}", "afmt": "{{FrontSide}}<hr id=answer>{{Front}}"}]},
            {"id": 3002, "name": "Cloze Facts", "type": 1, "flds": [{"name": "Text", "ord": 0}],
             "tmpls": [{"name": "Cloze", "ord": 0, "qfmt": "{{cloze:Text}}", "afmt": "{{cloze:Text}}"}]}
        ], "error": null}
        """)
        AnkiConnectStubProtocol.stub("retrieveMediaFile", #"{"result": "\#(Data("fake-mp3".utf8).base64EncodedString())", "error": null}"#)
    }

    func testImportDeckBuildsDecksNotesCardsAndHistory() async throws {
        let (_, decks, cards, reviews) = try makeStores()
        let importer = AnkiConnectImporter(client: try makeClient(), decks: decks, cards: cards, reviews: reviews)
        let mediaFile = try AppServices.mediaDirectory().appendingPathComponent("taberu.mp3")
        try? FileManager.default.removeItem(at: mediaFile)
        defer { try? FileManager.default.removeItem(at: mediaFile) }

        let stages = ProgressLog()
        let result = try await importer.importDeck(named: "Japanese") { progress in
            stages.record(progress.stage)
        }

        XCTAssertEqual(result.notesImported, 2)
        XCTAssertEqual(result.notesSkipped, 0)
        XCTAssertEqual(result.cardsImported, 3)
        XCTAssertEqual(result.reviewsImported, 2, "manual (type 4) revlog rows are not replayed")
        XCTAssertEqual(result.mediaImported, 1)
        XCTAssertEqual(result.mediaMissing, 0)
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        XCTAssertEqual(stages.all.first, .connecting)
        XCTAssertEqual(stages.all.last, .finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaFile.path))

        let root = try XCTUnwrap(try decks.deck(named: "Japanese"))
        XCTAssertEqual(result.deckID, root.id)
        let vocab = try XCTUnwrap(try decks.deck(named: "Japanese::Vocabulary"))

        let vocabCards = try cards.cards(inDeck: vocab.id).sorted { $0.templateOrdinal < $1.templateOrdinal }
        XCTAssertEqual(vocabCards.count, 2, "two templates → two cards for the vocab note")
        XCTAssertEqual(vocabCards[0].scheduling.kind, .review)
        XCTAssertEqual(vocabCards[0].scheduling.reps, 4)
        XCTAssertEqual(vocabCards[1].scheduling.kind, .new)
        XCTAssertEqual(try reviews.history(forCard: vocabCards[0].id).count, 2)

        let study = try XCTUnwrap(try cards.studyCard(id: vocabCards[0].id))
        XCTAssertEqual(study.note.fields, ["食べる", "to eat[sound:taberu.mp3]"])
        XCTAssertEqual(study.note.tags.sorted(), ["core", "vocab"])
        XCTAssertEqual(study.noteType.templates.map(\.name), ["Recognition", "Production"])

        let rootCards = try cards.cards(inDeck: root.id)
        XCTAssertEqual(rootCards.count, 1)
        XCTAssertEqual(rootCards[0].suspended, true, "queue -1 → suspended")
        XCTAssertEqual(rootCards[0].scheduling.kind, .review, "interval without history still lands in review")
        XCTAssertEqual(rootCards[0].scheduling.lapses, 1)
        XCTAssertEqual(try cards.studyCard(id: rootCards[0].id)?.noteType.kind, .cloze)
    }

    func testReimportSkipsExistingNotes() async throws {
        let (db, decks, cards, reviews) = try makeStores()
        let importer = AnkiConnectImporter(client: try makeClient(), decks: decks, cards: cards, reviews: reviews)

        _ = try await importer.importDeck(named: "Japanese", includeMedia: false)
        let second = try await importer.importDeck(named: "Japanese", includeMedia: false)
        XCTAssertEqual(second.notesImported, 0)
        XCTAssertEqual(second.notesSkipped, 2)
        XCTAssertEqual(second.cardsImported, 0)

        let total = try db.query("SELECT COUNT(*) FROM notes") { Int($0.int(0)) }.first
        XCTAssertEqual(total, 2)
    }

    func testEmptyDeckIsAnError() async throws {
        AnkiConnectStubProtocol.stub("findCards", #"{"result": [], "error": null}"#)
        let (_, decks, cards, reviews) = try makeStores()
        let importer = AnkiConnectImporter(client: try makeClient(), decks: decks, cards: cards, reviews: reviews)
        do {
            _ = try await importer.importDeck(named: "Empty", includeMedia: false)
            XCTFail("expected emptyDeck")
        } catch let error as AnkiConnectImporter.ImportError {
            guard case .emptyDeck(let name) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(name, "Empty")
        }
    }

    func testMediaReferencesSkipRemoteAndDataURLs() {
        let refs = AnkiConnectImporter.mediaReferences(in: [
            "[sound:a.mp3] and [sound:b%20c.mp3]",
            #"<img src="pic.jpg"><img src='https://example.com/x.png'><img src="data:image/png;base64,AAA">"#,
        ])
        XCTAssertEqual(refs, ["a.mp3", "b c.mp3", "pic.jpg"])
    }
}
