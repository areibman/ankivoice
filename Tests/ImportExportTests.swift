import XCTest
import Compression
@testable import AnkiVoice

final class ZipArchiveTests: XCTestCase {

    private func makeZip(entries: [(name: String, data: Data, method: UInt16, uncompressedSize: Int?)]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let offset = out.count
            out.appendLE(UInt32(0x04034b50))
            out.appendLE(UInt16(20))
            out.appendLE(UInt16(0))
            out.appendLE(UInt16(entry.method))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
            out.appendLE(UInt32(0))
            out.appendLE(UInt32(entry.data.count))
            out.appendLE(UInt32(entry.uncompressedSize ?? entry.data.count))
            out.appendLE(UInt16(nameBytes.count))
            out.appendLE(UInt16(0))
            out.append(contentsOf: nameBytes)
            out.append(entry.data)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(entry.method))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt32(entry.uncompressedSize ?? entry.data.count))
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt32(0))
            central.appendLE(UInt32(offset))
            central.append(contentsOf: nameBytes)
        }
        let cdOffset = out.count
        out.append(central)
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count)); out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(UInt32(cdOffset))
        out.appendLE(UInt16(0))
        return out
    }

    /// Raw DEFLATE compressor for fixture building.
    private func deflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        var destination = Data(count: capacity)
        let written = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            destination.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
                compression_encode_buffer(
                    target.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        destination.removeSubrange(written..<destination.count)
        return destination
    }

    func testStoredEntries() throws {
        let data = makeZip(entries: [
            ("media", Data("{}".utf8), 0, nil),
            ("0", Data("binary-sound".utf8), 0, nil),
        ])
        let zip = try ZipReader(data: data)
        XCTAssertEqual(zip.entries.map(\.name), ["media", "0"])
        XCTAssertEqual(try zip.extract("media"), Data("{}".utf8))
        XCTAssertEqual(try zip.extract("0"), Data("binary-sound".utf8))
    }

    func testDeflateRoundTrip() throws {
        let payload = Data(String(repeating: "The powerhouse of the cell. ", count: 50).utf8)
        let compressed = deflate(payload)
        let data = makeZip(entries: [("collection.anki2", compressed, 8, payload.count)])
        let zip = try ZipReader(data: data)
        XCTAssertEqual(try zip.extract("collection.anki2"), payload)
    }

    func testNonZipRejected() {
        XCTAssertThrowsError(try ZipReader(data: Data("not a zip".utf8)))
    }

    /// A multi-megabyte entry exercises the streaming inflater across many
    /// output chunks (the in-memory path used for collection.anki2).
    func testLargeDeflateEntryStreamsAcrossChunks() throws {
        var payload = Data(capacity: 3 * 1024 * 1024)
        var state: UInt32 = 12345
        for _ in 0..<(3 * 1024 * 1024 / 4) {
            state = state &* 1_103_515_245 &+ 12345
            // Low entropy so deflate actually compresses, but not constant.
            payload.appendLE(UInt32(state >> 28))
        }
        let compressed = deflate(payload)
        XCTAssertLessThan(compressed.count, payload.count)
        let zip = try ZipReader(data: makeZip(entries: [("collection.anki2", compressed, 8, payload.count)]))
        XCTAssertEqual(try zip.extract("collection.anki2"), payload)
    }

    /// `extract(_:to:)` is the media path: bytes go straight to disk.
    func testExtractToDiskMatchesInMemory() throws {
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let zip = try ZipReader(data: makeZip(entries: [
            ("0", deflate(payload), 8, payload.count),
            ("1", payload, 0, nil),
        ]))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["0", "1"] {
            let url = dir.appendingPathComponent(name)
            try zip.extract(name, to: url)
            XCTAssertEqual(try Data(contentsOf: url), payload, "entry \(name)")
        }
        // Replacing an existing file works too (re-import over old media).
        try zip.extract("1", to: dir.appendingPathComponent("0"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("0")), payload)
    }

    func testCorruptDeflateIsReportedNotCrashed() throws {
        let payload = Data(String(repeating: "abc", count: 1000).utf8)
        var compressed = deflate(payload)
        for i in stride(from: 8, to: compressed.count, by: 7) { compressed[i] ^= 0xFF }
        let zip = try ZipReader(data: makeZip(entries: [("collection.anki2", compressed, 8, payload.count)]))
        XCTAssertThrowsError(try zip.extract("collection.anki2")) { error in
            guard case ZipReader.ZipError.corruptEntry("collection.anki2") = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testTruncatedArchiveIsRejectedNotCrashed() throws {
        // High-entropy payload so the compressed entry stays a few KB long.
        var state: UInt32 = 99
        let payload = Data((0..<20_000).map { _ -> UInt8 in
            state = state &* 1_103_515_245 &+ 12345
            return UInt8(truncatingIfNeeded: state >> 24)
        })
        let full = makeZip(entries: [("collection.anki2", deflate(payload), 8, payload.count)])
        XCTAssertGreaterThan(full.count, 1000)
        // Cut through the compressed data but keep the central directory
        // pointing past the end: the reader must bounds-check, not trap.
        var truncated = full
        truncated.removeSubrange(40..<(40 + 300))
        XCTAssertThrowsError(try ZipReader(data: truncated).extract("collection.anki2"))
        // And every prefix of the archive must fail cleanly.
        for cut in [0, 3, 22, 30, 100, full.count - 1] {
            XCTAssertThrowsError(try ZipReader(data: full.prefix(cut)), "prefix \(cut)")
        }
    }

    func testZstdZipMethodRejectsGarbage() throws {
        let zip = try ZipReader(data: makeZip(entries: [("collection.anki21b", Data([1, 2, 3]), 93, 3)]))
        XCTAssertThrowsError(try zip.extract("collection.anki21b")) { error in
            guard case ZipReader.ZipError.corruptEntry(let entry) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(entry, "collection.anki21b")
        }
    }

    func testZstdFrameRoundTrip() throws {
        let hex = "28b52ffd045851000068656c6c6f207a737464cfdb609c"
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        XCTAssertTrue(Zstd.isFrame(bytes))
        XCTAssertEqual(try Zstd.decompress(bytes), Data("hello zstd".utf8))
    }

    func testWriterRoundTrip() throws {
        var writer = ZipWriter()
        writer.add(name: "a.txt", data: Data("hello".utf8))
        writer.add(name: "dir/b.bin", data: Data([0, 1, 2, 255]))
        let data = writer.finalize()
        let zip = try ZipReader(data: data)
        XCTAssertEqual(try zip.extract("a.txt"), Data("hello".utf8))
        XCTAssertEqual(try zip.extract("dir/b.bin"), Data([0, 1, 2, 255]))
    }
}

final class SQLiteTransactionTests: XCTestCase {

    private func count(_ db: SQLiteDatabase) throws -> Int {
        try db.query("SELECT COUNT(*) FROM t") { Int($0.int(0)) }.first ?? -1
    }

    /// The importer wraps batches in a transaction while `createNote` opens
    /// its own; SQLite rejects a nested BEGIN, so nesting must be handled.
    func testNestedTransactionsCommitTogether() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.execute("CREATE TABLE t (v INTEGER)")
        try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            try db.transaction {
                try db.run("INSERT INTO t VALUES (2)")
                try db.transaction { try db.run("INSERT INTO t VALUES (3)") }
            }
        }
        XCTAssertEqual(try count(db), 3)
    }

    func testInnerFailureRollsBackOnlyItsOwnWork() throws {
        struct Boom: Error {}
        let db = try SQLiteDatabase.inMemory()
        try db.execute("CREATE TABLE t (v INTEGER)")
        try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            XCTAssertThrowsError(try db.transaction {
                try db.run("INSERT INTO t VALUES (2)")
                throw Boom()
            })
            try db.run("INSERT INTO t VALUES (3)")
        }
        XCTAssertEqual(try db.query("SELECT v FROM t ORDER BY v") { Int($0.int(0)) }, [1, 3])
    }

    func testOuterFailureRollsBackEverything() throws {
        struct Boom: Error {}
        let db = try SQLiteDatabase.inMemory()
        try db.execute("CREATE TABLE t (v INTEGER)")
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            try db.transaction { try db.run("INSERT INTO t VALUES (2)") }
            throw Boom()
        })
        XCTAssertEqual(try count(db), 0)
        // And the connection is usable afterwards (depth reset).
        try db.transaction { try db.run("INSERT INTO t VALUES (9)") }
        XCTAssertEqual(try count(db), 1)
    }
}

final class DelimitedTextImporterTests: XCTestCase {

    private func makeStores() throws -> (SQLiteDatabase, CardRepository, DeckRepository) {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        return (db, CardRepository(db: db), DeckRepository(db: db))
    }

    func testCSVDetectionAndImport() throws {
        let (db, cards, decks) = try makeStores()
        let importer = DelimitedTextImporter(cards: cards, decks: decks)
        let csv = "Capital of France?,Paris,geography capitals\n"
            + "\"Comma, in front\",\"Quoted \"\"back\"\"\",extra\n"
            + "2 + 2,Four\n"
        let result = try importer.importText(csv, intoDeck: "Imported")
        XCTAssertEqual(result.notesImported, 3)
        XCTAssertEqual(result.notesSkipped, 0)

        let all = try cards.cards(inDeck: result.deckID)
        XCTAssertEqual(all.count, 3)
        let first = try XCTUnwrap(try cards.studyCard(id: all[0].id))
        XCTAssertEqual(first.note.front, "Capital of France?")
        XCTAssertEqual(first.note.back, "Paris")
        XCTAssertEqual(first.note.tags, ["geography", "capitals"])
        let second = try XCTUnwrap(try cards.studyCard(id: all[1].id))
        XCTAssertEqual(second.note.front, "Comma, in front")
        XCTAssertEqual(second.note.back, "Quoted \"back\"")
    }

    func testTSVWithHeader() throws {
        let (db, cards, decks) = try makeStores()
        let importer = DelimitedTextImporter(cards: cards, decks: decks)
        XCTAssertEqual(DelimitedTextImporter.detectFormat("a\tb\n1\t2\n"), .tab)
        let tsv = "Front\tBack\nたべる\tto eat\n飲む\tto drink\n"
        let result = try importer.importText(tsv, intoDeck: "Japanese", format: .tab, hasHeader: true)
        XCTAssertEqual(result.notesImported, 2)
        let all = try cards.cards(inDeck: result.deckID)
        XCTAssertEqual(all.count, 2)
    }

    func testMalformedRowsSkipped() throws {
        let (db, cards, decks) = try makeStores()
        let importer = DelimitedTextImporter(cards: cards, decks: decks)
        let csv = "only-one-column\nfront,back\n\n"
        let result = try importer.importText(csv, intoDeck: "X")
        XCTAssertEqual(result.notesImported, 1)
        XCTAssertEqual(result.notesSkipped, 1)
    }
}

final class ApkgImporterTests: XCTestCase {

    private func makeApkg() throws -> Data {
        let ankiURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anki2-fixture-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: ankiURL) }
        let db = try SQLiteDatabase.open(url: ankiURL)

        let ddl = [
            """
            CREATE TABLE col (
                id INTEGER PRIMARY KEY, crt INTEGER, mod INTEGER, scm INTEGER, ver INTEGER,
                dty INTEGER, usn INTEGER, ls INTEGER, conf TEXT,
                models TEXT, decks TEXT, dconf TEXT, tags TEXT
            );
            """,
            """
            CREATE TABLE notes (
                id INTEGER PRIMARY KEY, guid TEXT, mid INTEGER, mod INTEGER, usn INTEGER,
                tags TEXT, flds TEXT, sfld TEXT, csum INTEGER, flags INTEGER, data TEXT
            );
            """,
            """
            CREATE TABLE cards (
                id INTEGER PRIMARY KEY, nid INTEGER, did INTEGER, ord INTEGER,
                type INTEGER, queue INTEGER, due INTEGER, ivl INTEGER, factor INTEGER,
                reps INTEGER, lapses INTEGER, left INTEGER, odue INTEGER, odid INTEGER,
                flags INTEGER, data TEXT
            );
            """,
            """
            CREATE TABLE revlog (
                id INTEGER PRIMARY KEY, cid INTEGER, usn INTEGER, ease INTEGER,
                ivl INTEGER, lastIvl INTEGER, factor INTEGER, time INTEGER, type INTEGER
            );
            """,
        ]
        for statement in ddl { try db.execute(statement) }

        let crt = 1_600_000_000
        let decksJSON = """
        [
          {"id": 1, "name": "Default"},
          {"id": 1425368048697, "name": "Default"},
          {"id": 1700000000001, "name": "Languages::Japanese::Vocabulary"},
          {"id": 1700000000002, "name": "Geography"}
        ]
        """
        let modelsJSON = """
        {
          "1700000000010": {
            "id": 1700000000010, "name": "Japanese Vocab", "type": 0,
            "flds": [{"name": "Front"}, {"name": "Back"}],
            "tmpls": [{"name": "Card 1", "qfmt": "{{Front}}", "afmt": "{{FrontSide}}<hr id=answer>{{Back}}", "ord": 0}]
          },
          "1700000000011": {
            "id": 1700000000011, "name": "Cloze Facts", "type": 1,
            "flds": [{"name": "Text"}],
            "tmpls": [{"name": "Cloze", "qfmt": "{{cloze:Text}}", "afmt": "{{cloze:Text}}", "ord": 0}]
          }
        }
        """
        try db.run(
            "INSERT INTO col (crt, ver, models, decks, conf, dconf, tags) VALUES (?,?,?,?,?,?,?)",
            [.int(Int64(crt)), .int(11), .text(modelsJSON), .text(decksJSON),
             .text("{}"), .text("{}"), .text("")]
        )

        let note1 = Int64(1_700_000_000_1001)
        let note2 = Int64(1_700_000_000_1002)
        let note3 = Int64(1_700_000_000_1003)
        try db.run(
            "INSERT INTO notes (id, guid, mid, tags, flds, sfld, csum) VALUES (?,?,?,?,?,?,0)",
            [.int(note1), .text("guid-taberu"), .int(Int64(1_700_000_000_010)), .text("core vocab"),
             .text("食べる\u{1f}to eat"), .text("食べる")]
        )
        try db.run(
            "INSERT INTO notes (id, guid, mid, tags, flds, sfld, csum) VALUES (?,?,?,?,?,?,0)",
            [.int(note2), .text("guid-cloze"), .int(Int64(1_700_000_000_011)), .text(""),
             .text("The powerhouse of the cell is the {{c1::mitochondrion}}."), .text("powerhouse")]
        )
        try db.run(
            "INSERT INTO notes (id, guid, mid, tags, flds, sfld, csum) VALUES (?,?,?,?,?,?,0)",
            [.int(note3), .text("guid-geography"), .int(Int64(1_700_000_000_010)), .text(""),
             .text("Capital of France?\u{1f}Paris"), .text("Capital of France?")]
        )

        let card1 = Int64(1_700_000_000_2001)
        let cardInsert = "INSERT INTO cards (id, nid, did, ord, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        try db.run(cardInsert, [
            .int(card1), .int(note1), .int(Int64(1_700_000_000_001)), .int(0), .int(2), .int(2),
            .int(Int64(crt + 30 * 86_400)), .int(30), .int(2500), .int(4), .int(0),
            .int(0), .int(0), .int(0), .int(0),
            .text(#"{"s": 12.5, "d": 5.2}"#),
        ])
        try db.run(cardInsert, [
            .int(Int64(1_700_000_000_2002)), .int(note2), .int(Int64(1_700_000_000_001)), .int(0), .int(0), .int(0),
            .int(1), .int(0), .int(0), .int(0), .int(0),
            .int(0), .int(0), .int(0), .int(0), .text(""),
        ])
        let card3 = Int64(1_700_000_000_2003)
        try db.run(cardInsert, [
            .int(card3), .int(note3), .int(Int64(1_700_000_000_002)), .int(0), .int(2), .int(-1),
            .int(Int64(crt + 5 * 86_400)), .int(5), .int(2300), .int(2), .int(0),
            .int(0), .int(0), .int(0), .int(0), .text(""),
        ])

        let revlogInsert = "INSERT INTO revlog (id, cid, ease, ivl, lastIvl, factor, time, type) VALUES (?,?,?,?,?,?,?,?)"
        let baseMs = Int64(1_600_000_000_000)
        try db.run(revlogInsert, [.int(baseMs + 1000), .int(card1), .int(3), .int(1), .int(0), .int(0), .int(3000), .int(0)])
        try db.run(revlogInsert, [.int(baseMs + 86_400_000), .int(card1), .int(3), .int(3), .int(1), .int(0), .int(2500), .int(1)])
        try db.run(revlogInsert, [.int(baseMs + 5000), .int(card3), .int(1), .int(10), .int(0), .int(0), .int(4000), .int(0)])

        // Flush WAL so the .sqlite file is self-contained.
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.execute("PRAGMA journal_mode=DELETE")
        let dbData = try Data(contentsOf: ankiURL)

        var writer = ZipWriter()
        writer.add(name: "collection.anki2", data: dbData)
        let mediaJSON = try JSONSerialization.data(withJSONObject: ["0": "taberu.mp3"])
        writer.add(name: "media", data: mediaJSON)
        writer.add(name: "0", data: Data("fake-mp3-bytes".utf8))
        return writer.finalize()
    }

    private func makeStores() throws -> (SQLiteDatabase, DeckRepository, CardRepository, ReviewRepository) {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        return (db, DeckRepository(db: db), CardRepository(db: db), ReviewRepository(db: db))
    }

    func testApkgImport() throws {
        let apkg = try makeApkg()
        let (db, decks, cards, reviews) = try makeStores()
        let importer = ApkgImporter(decks: decks, cards: cards, reviews: reviews)

        let result = try importer.importPackage(zip: ZipReader(data: apkg))
        XCTAssertEqual(result.notesImported, 3)
        XCTAssertEqual(result.cardsImported, 3)
        XCTAssertGreaterThanOrEqual(result.reviewsImported, 3)

        XCTAssertNotNil(try decks.deck(named: "Languages::Japanese::Vocabulary"))
        XCTAssertNotNil(try decks.deck(named: "Geography"))

        let vocabDeck = try XCTUnwrap(try decks.deck(named: "Languages::Japanese::Vocabulary"))
        let vocabCards = try cards.cards(inDeck: vocabDeck.id)
        XCTAssertEqual(vocabCards.count, 2)

        let reviewed = try XCTUnwrap(vocabCards.first { $0.scheduling.kind == .review })
        XCTAssertEqual(reviewed.scheduling.stability ?? 0, 12.5, accuracy: 1e-9)
        XCTAssertEqual(reviewed.scheduling.difficulty ?? 0, 5.2, accuracy: 1e-9)

                let newCard = try XCTUnwrap(vocabCards.first { $0.scheduling.kind == .new })
        let clozeCard = try XCTUnwrap(try cards.studyCard(id: newCard.id))
        XCTAssertEqual(clozeCard.noteType.kind, .cloze)
        XCTAssertEqual(clozeCard.note.fields.first, "The powerhouse of the cell is the {{c1::mitochondrion}}.")

        let geoDeck = try XCTUnwrap(try decks.deck(named: "Geography"))
        let geoCards = try cards.cards(inDeck: geoDeck.id)
        XCTAssertEqual(geoCards.count, 1)
        XCTAssertEqual(geoCards.first?.suspended, true)

        let history = try reviews.history(forCard: reviewed.id)
        XCTAssertEqual(history.count, 2)

        let mediaDir = try AppServices.mediaDirectory()
        let mediaFile = mediaDir.appendingPathComponent("taberu.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaFile.path))
        try? FileManager.default.removeItem(at: mediaFile)
    }

    func testApkgReimportDeduplicatesByGuid() throws {
        let apkg = try makeApkg()
        let (db, decks, cards, reviews) = try makeStores()
        let importer = ApkgImporter(decks: decks, cards: cards, reviews: reviews)

        _ = try importer.importPackage(zip: ZipReader(data: apkg))
        let second = try importer.importPackage(zip: ZipReader(data: apkg))
        XCTAssertEqual(second.notesImported, 0, "guids prevent duplicate imports")

        let total = try db.query("SELECT COUNT(*) FROM notes") { Int($0.int(0)) }.first
        XCTAssertEqual(total, 3)
    }

    // MARK: Large packages

    /// Builds a package with `noteCount` two-card notes and a review log per
    /// card — the shape of a real shared deck, scaled down.
    private func makeLargeApkg(noteCount: Int) throws -> Data {
        let ankiURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anki2-large-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: ankiURL) }
        let db = try SQLiteDatabase.open(url: ankiURL)
        for statement in [
            "CREATE TABLE col (id INTEGER PRIMARY KEY, crt INTEGER, mod INTEGER, scm INTEGER, ver INTEGER, dty INTEGER, usn INTEGER, ls INTEGER, conf TEXT, models TEXT, decks TEXT, dconf TEXT, tags TEXT);",
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, guid TEXT, mid INTEGER, mod INTEGER, usn INTEGER, tags TEXT, flds TEXT, sfld TEXT, csum INTEGER, flags INTEGER, data TEXT);",
            "CREATE TABLE cards (id INTEGER PRIMARY KEY, nid INTEGER, did INTEGER, ord INTEGER, type INTEGER, queue INTEGER, due INTEGER, ivl INTEGER, factor INTEGER, reps INTEGER, lapses INTEGER, left INTEGER, odue INTEGER, odid INTEGER, flags INTEGER, data TEXT);",
            "CREATE TABLE revlog (id INTEGER PRIMARY KEY, cid INTEGER, usn INTEGER, ease INTEGER, ivl INTEGER, lastIvl INTEGER, factor INTEGER, time INTEGER, type INTEGER);",
        ] { try db.execute(statement) }

        let crt = 1_600_000_000
        let models = """
        {"1700000000010": {"id": 1700000000010, "name": "Vocab", "type": 0,
          "flds": [{"name": "Front"}, {"name": "Back"}],
          "tmpls": [{"name": "Recognition", "qfmt": "{{Front}}", "afmt": "{{Back}}", "ord": 0},
                    {"name": "Recall", "qfmt": "{{Back}}", "afmt": "{{Front}}", "ord": 1}]}}
        """
        try db.run(
            "INSERT INTO col (crt, ver, models, decks, conf, dconf, tags) VALUES (?,?,?,?,?,?,?)",
            [.int(Int64(crt)), .int(11), .text(models),
             .text(#"[{"id": 1, "name": "Default"}, {"id": 1700000000001, "name": "Big"}]"#),
             .text("{}"), .text("{}"), .text("")]
        )
        try db.transaction {
            let noteInsert = "INSERT INTO notes (id, guid, mid, tags, flds, sfld, csum) VALUES (?,?,?,?,?,?,0)"
            let cardInsert = "INSERT INTO cards (id, nid, did, ord, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            let revlogInsert = "INSERT INTO revlog (id, cid, ease, ivl, lastIvl, factor, time, type) VALUES (?,?,?,?,?,?,?,?)"
            for i in 0..<noteCount {
                let noteID = Int64(2_000_000_000_000) + Int64(i)
                try db.run(noteInsert, [
                    .int(noteID), .text("guid-\(i)"), .int(1_700_000_000_010), .text("big"),
                    .text("word \(i)\u{1f}meaning \(i)"), .text("word \(i)"),
                ])
                for ord in 0..<2 {
                    let cardID = Int64(3_000_000_000_000) + Int64(i * 2 + ord)
                    try db.run(cardInsert, [
                        .int(cardID), .int(noteID), .int(1_700_000_000_001), .int(Int64(ord)), .int(2), .int(2),
                        .int(Int64(crt + 10 * 86_400)), .int(10), .int(2500), .int(3), .int(0),
                        .int(0), .int(0), .int(0), .int(0), .text(""),
                    ])
                    try db.run(revlogInsert, [
                        .int(Int64(1_600_000_000_000) + Int64(i * 2 + ord)), .int(cardID),
                        .int(3), .int(10), .int(1), .int(2500), .int(3000), .int(1),
                    ])
                }
            }
        }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.execute("PRAGMA journal_mode=DELETE")

        var writer = ZipWriter()
        writer.add(name: "collection.anki2", data: try Data(contentsOf: ankiURL))
        writer.add(name: "media", data: Data("{}".utf8))
        return writer.finalize()
    }

    /// Regression guard for the O(N²) card lookup and per-row transactions
    /// that made big shared decks hang (and get killed) on import.
    func testLargeApkgImportsInBoundedTime() throws {
        let noteCount = 3000
        let apkg = try makeLargeApkg(noteCount: noteCount)
        let (db, decks, cards, reviews) = try makeStores()
        let importer = ApkgImporter(decks: decks, cards: cards, reviews: reviews)

        // The progress handler is @Sendable; collect fractions through a box.
        final class Fractions: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []
            func append(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
            var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let fractions = Fractions()
        let started = Date()
        let result = try importer.importPackage(zip: ZipReader(data: apkg)) { fraction, _ in
            fractions.append(fraction)
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.notesImported, noteCount)
        XCTAssertEqual(result.cardsImported, noteCount * 2)
        XCTAssertEqual(result.reviewsImported, noteCount * 2)
        let reported = fractions.all
        XCTAssertGreaterThan(reported.count, 10, "batched import reports progress as it goes")
        XCTAssertEqual(reported, reported.sorted(), "progress must be monotonic")
        XCTAssertLessThan(elapsed, 20, "3k notes took \(elapsed)s; the import path has regressed")

        let big = try XCTUnwrap(try decks.deck(named: "Big"))
        XCTAssertEqual(try cards.cards(inDeck: big.id).count, noteCount * 2)
        let total = try db.query("SELECT COUNT(*) FROM notes") { Int($0.int(0)) }.first
        XCTAssertEqual(total, noteCount)
    }
}

final class ExportServiceTests: XCTestCase {

    func testCSVRoundTrip() throws {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        let decks = DeckRepository(db: db)
        let cards = CardRepository(db: db)
        let deck = try decks.create(fullName: "Export")
        _ = try cards.createNote(fields: ["Front, comma", "Back \"q\""], tags: ["tag1", "tag2"], deckID: deck.id)

        let all = try cards.search(query: "", deckID: deck.id)
        let exporter = ExportService()
        let csv = exporter.exportCSV(cards: all, includeProgress: false)
        XCTAssertTrue(csv.contains("\"Front, comma\""))
        XCTAssertTrue(csv.contains("\"Back \"\"q\"\"\""))

        let importer = DelimitedTextImporter(cards: cards, decks: decks)
        let result = try importer.importText(csv, intoDeck: "RoundTrip", hasHeader: true)
        XCTAssertEqual(result.notesImported, 1)
    }

    func testIncludeProgressColumns() throws {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        let decks = DeckRepository(db: db)
        let cards = CardRepository(db: db)
        let deck = try decks.create(fullName: "Export")
        _ = try cards.createNote(fields: ["Q", "A"], deckID: deck.id)

        let all = try cards.search(query: "", deckID: deck.id)
        let csv = ExportService().exportCSV(cards: all, includeProgress: true)
        XCTAssertTrue(csv.contains("Stability"))
        XCTAssertTrue(csv.contains("new"))
    }
}

final class ApkgExporterTests: XCTestCase {

    private func makeStores() throws -> (SQLiteDatabase, DeckRepository, CardRepository, ReviewRepository) {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db: db)
        return (db, DeckRepository(db: db), CardRepository(db: db), ReviewRepository(db: db))
    }

    private func seedReviewedCard(
        decks: DeckRepository, cards: CardRepository, reviews: ReviewRepository
    ) throws -> (Deck, Card) {
        let deck = try decks.create(fullName: "Languages::Japanese")
        let note = try cards.createNote(
            fields: ["食べる", "to eat"], tags: ["core", "vocab"], deckID: deck.id
        )
        let card = try XCTUnwrap(try cards.cards(forNote: note.id).first)
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let due = Date(timeIntervalSince1970: 1_700_000_000 + 12.5 * 86_400)
        let after = SchedulingState(
            kind: .review, stability: 12.5, difficulty: 5.2,
            due: due, lastReview: reviewedAt, lapses: 0, reps: 2
        )
        try cards.replaceScheduling(after, cardID: card.id)
        _ = try reviews.append(ReviewLog(
            id: 0, cardID: card.id, rating: .good, reviewedAt: reviewedAt,
            durationMs: 3_000, studyMode: .touch,
            previousState: SchedulingState(), newState: after
        ))
        _ = try reviews.append(ReviewLog(
            id: 0, cardID: card.id, rating: .easy,
            reviewedAt: reviewedAt.addingTimeInterval(86_400),
            durationMs: 1_200, studyMode: .voice,
            previousState: after, newState: after
        ))
        return (deck, try XCTUnwrap(try cards.card(id: card.id)))
    }

    func testApkgRoundTripPreservesSchedulingAndHistory() throws {
        let (_, decks, cards, reviews) = try makeStores()
        let (deck, _) = try seedReviewedCard(decks: decks, cards: cards, reviews: reviews)

        let geo = try decks.create(fullName: "Geography")
        let geoNote = try cards.createNote(fields: ["Capital of France?", "Paris"], deckID: geo.id)
        let geoCard = try XCTUnwrap(try cards.cards(forNote: geoNote.id).first)
        try cards.setSuspended(true, cardID: geoCard.id)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exporter = ApkgExporter(decks: decks, cards: cards, reviews: reviews)
        let exported = try exporter.exportDeck(id: deck.id, to: dir)
        XCTAssertEqual(exported.notesExported, 1)
        XCTAssertEqual(exported.cardsExported, 1)
        XCTAssertEqual(exported.reviewsExported, 2)
        XCTAssertEqual(exported.url.pathExtension, "apkg")

        let zip = try ZipReader(data: try Data(contentsOf: exported.url))
        XCTAssertNotNil(zip.entry(named: "collection.anki2"))
        XCTAssertNotNil(zip.entry(named: "media"))

        let (_, inDecks, inCards, inReviews) = try makeStores()
        let imported = try ApkgImporter(decks: inDecks, cards: inCards, reviews: inReviews)
            .importPackage(zip: zip)
        XCTAssertEqual(imported.notesImported, 1)
        XCTAssertEqual(imported.reviewsImported, 2)

        let vocab = try XCTUnwrap(try inDecks.deck(named: "Languages::Japanese"))
        let vocabCards = try inCards.cards(inDeck: vocab.id)
        XCTAssertEqual(vocabCards.count, 1)
        let reviewed = try XCTUnwrap(vocabCards.first)
        XCTAssertEqual(reviewed.scheduling.kind, .review)
        XCTAssertEqual(reviewed.scheduling.stability ?? 0, 12.5, accuracy: 1e-9)
        XCTAssertEqual(reviewed.scheduling.difficulty ?? 0, 5.2, accuracy: 1e-9)
        XCTAssertEqual(try inReviews.history(forCard: reviewed.id).count, 2)

        XCTAssertNil(try inDecks.deck(named: "Geography"), "deck export must not include sibling decks")
    }

    func testCardsOnlyExportStripsScheduling() throws {
        let (_, decks, cards, reviews) = try makeStores()
        let (deck, _) = try seedReviewedCard(decks: decks, cards: cards, reviews: reviews)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exported = try ApkgExporter(decks: decks, cards: cards, reviews: reviews)
            .exportDeck(id: deck.id, options: .cardsOnly, to: dir)
        XCTAssertEqual(exported.reviewsExported, 0)

        let (_, inDecks, inCards, inReviews) = try makeStores()
        _ = try ApkgImporter(decks: inDecks, cards: inCards, reviews: inReviews)
            .importPackage(zip: ZipReader(data: try Data(contentsOf: exported.url)))
        let vocab = try XCTUnwrap(try inDecks.deck(named: "Languages::Japanese"))
        let imported = try XCTUnwrap(try inCards.cards(inDeck: vocab.id).first)
        XCTAssertEqual(imported.scheduling.kind, .new)
        XCTAssertNil(imported.scheduling.stability)
        XCTAssertEqual(try inReviews.history(forCard: imported.id).count, 0)
    }

    func testCollectionExportIncludesEveryDeckAndUsesColpkg() throws {
        let (_, decks, cards, reviews) = try makeStores()
        _ = try seedReviewedCard(decks: decks, cards: cards, reviews: reviews)
        _ = try decks.create(fullName: "Empty")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exported = try ApkgExporter(decks: decks, cards: cards, reviews: reviews)
            .exportCollection(to: dir)
        XCTAssertEqual(exported.url.pathExtension, "colpkg")
        XCTAssertEqual(exported.notesExported, 1)

        let (_, inDecks, inCards, inReviews) = try makeStores()
        _ = try ApkgImporter(decks: inDecks, cards: inCards, reviews: inReviews)
            .importPackage(at: exported.url)
        XCTAssertNotNil(try inDecks.deck(named: "Languages::Japanese"))
        XCTAssertNotNil(try inDecks.deck(named: "Empty"))
    }

    func testExportIncludesReferencedMedia() throws {
        let (_, decks, cards, reviews) = try makeStores()
        let deck = try decks.create(fullName: "Audio")
        _ = try cards.createNote(
            fields: ["[sound:export-test.mp3]", "a clip"], deckID: deck.id
        )

        let mediaDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mediaDir) }
        try Data("fake-mp3".utf8).write(to: mediaDir.appendingPathComponent("export-test.mp3"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exported = try ApkgExporter(decks: decks, cards: cards, reviews: reviews)
            .exportDeck(id: deck.id, mediaDirectory: mediaDir, to: dir)
        XCTAssertEqual(exported.mediaExported, 1)

        let zip = try ZipReader(data: try Data(contentsOf: exported.url))
        let mapping = try JSONDecoder().decode([String: String].self, from: zip.extract("media"))
        XCTAssertEqual(Array(mapping.values), ["export-test.mp3"])
        XCTAssertEqual(try zip.extract("0"), Data("fake-mp3".utf8))
    }

    func testChildDecksAreIncluded() throws {
        let (_, decks, cards, reviews) = try makeStores()
        let parent = try decks.create(fullName: "Parent")
        let child = try decks.create(fullName: "Parent::Child")
        _ = try cards.createNote(fields: ["Q", "A"], deckID: child.id)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exported = try ApkgExporter(decks: decks, cards: cards, reviews: reviews)
            .exportDeck(id: parent.id, to: dir)
        XCTAssertEqual(exported.notesExported, 1)

        let (_, inDecks, inCards, inReviews) = try makeStores()
        _ = try ApkgImporter(decks: inDecks, cards: inCards, reviews: inReviews)
            .importPackage(at: exported.url)
        XCTAssertNotNil(try inDecks.deck(named: "Parent::Child"))
        let importedChild = try XCTUnwrap(try inDecks.deck(named: "Parent::Child"))
        XCTAssertEqual(try inCards.cards(inDeck: importedChild.id).count, 1)
    }

    func testRelationalZstdSchemaImport() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rel-\(UUID().uuidString).sqlite")
        let source = try SQLiteDatabase.open(url: url)
        try source.execute("CREATE TABLE col (id INTEGER PRIMARY KEY, crt REAL)")
        try source.execute("CREATE TABLE decks (id INTEGER PRIMARY KEY, name TEXT)")
        try source.execute("CREATE TABLE notetypes (id INTEGER PRIMARY KEY, name TEXT, config BLOB)")
        try source.execute("CREATE TABLE fields (ntid INTEGER, ord INTEGER, name TEXT)")
        try source.execute("CREATE TABLE templates (ntid INTEGER, ord INTEGER, name TEXT, config BLOB)")
        try source.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, guid TEXT, mid INTEGER, tags TEXT, flds TEXT, mod REAL)")
        try source.execute("CREATE TABLE cards (id INTEGER PRIMARY KEY, nid INTEGER, did INTEGER, ord INTEGER, type INTEGER, queue INTEGER, due REAL, ivl INTEGER, factor INTEGER, reps INTEGER, lapses INTEGER, data TEXT)")
        try source.execute("CREATE TABLE revlog (id INTEGER, cid INTEGER, ease INTEGER, time INTEGER, type INTEGER)")
        try source.run("INSERT INTO col (id, crt) VALUES (1, ?)", [.double(1_600_000_000)])
        try source.run("INSERT INTO decks (id, name) VALUES (10, ?)", [.text("Languages::Japanese")])
        var noteConfig = Data()
        ProtobufWriter.appendVarint(1, field: 1, to: &noteConfig)
        try source.run("INSERT INTO notetypes (id, name, config) VALUES (5, ?, ?)", [.text("Cloze"), .blob(noteConfig)])
        try source.run("INSERT INTO fields (ntid, ord, name) VALUES (5, 0, 'Text'), (5, 1, 'Back Extra')")
        var templateConfig = Data()
        ProtobufWriter.appendString("{{cloze:Text}}", field: 1, to: &templateConfig)
        ProtobufWriter.appendString("{{cloze:Text}}<hr>{{Back Extra}}", field: 2, to: &templateConfig)
        try source.run(
            "INSERT INTO templates (ntid, ord, name, config) VALUES (5, 0, 'Cloze', ?)",
            [.blob(templateConfig)]
        )
        try source.run(
            "INSERT INTO notes (id, guid, mid, tags, flds, mod) VALUES (1, 'g', 5, 'vocab', ?, 1)",
            [.text("The {{c1::cat}}\u{1f}noun")]
        )
        try source.run(
            "INSERT INTO cards (id, nid, did, ord, type, queue, due, ivl, factor, reps, lapses, data) VALUES (1, 1, 10, 0, 0, 0, 0, 0, 0, 0, 0, '')"
        )
        try source.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try source.execute("PRAGMA journal_mode=DELETE")
        let dbData = try Data(contentsOf: url)
        // collection.anki21b is a zstd frame in real packages. This fixture is
        // the decoded SQLite so the relational reader is what's under test;
        // the frame decoder is covered by testZstdFrameRoundTrip.
        var writer = ZipWriter()
        writer.add(name: "collection.anki21b", data: dbData)
        writer.add(name: "media", data: Data("{}".utf8))
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("rel-\(UUID().uuidString).colpkg")
        try writer.finalize().write(to: package)
        defer { try? FileManager.default.removeItem(at: package) }

        let (_, decks, cards, reviews) = try makeStores()
        let result = try ApkgImporter(decks: decks, cards: cards, reviews: reviews).importPackage(at: package)
        XCTAssertEqual(result.notesImported, 1)
        XCTAssertNotNil(try decks.deck(named: "Languages::Japanese"))
        let imported = try XCTUnwrap(try cards.allStudyCards().first { $0.note.guid == "g" })
        XCTAssertEqual(imported.noteType.kind, .cloze)
        XCTAssertEqual(imported.noteType.templates.first?.questionFormat, "{{cloze:Text}}")
        XCTAssertTrue(imported.note.fields[0].contains("cat"))
    }

    /// Everyday Portuguese exports the note-type id as a string and only
    /// generates the second card type (Speak). Both are valid Anki.
    func testStringNoteTypeIDAndPartialCardsImport() throws {
        let (_, decksRepo, cards, reviews) = try makeStores()
        let result = try ApkgImporter(decks: decksRepo, cards: cards, reviews: reviews)
            .importPackage(zip: ZipReader(data: try portugueseSpeakPackage()))
        XCTAssertEqual(result.notesImported, 1)
        XCTAssertEqual(result.cardsImported, 1)
        let deck = try XCTUnwrap(try decksRepo.deck(named: "Portuguese - Everyday"))
        let imported = try cards.cards(inDeck: deck.id)
        XCTAssertEqual(imported.count, 1, "the Understand card was not in the package")
        XCTAssertEqual(imported.first?.templateOrdinal, 1)
        let study = try XCTUnwrap(try cards.studyCard(id: imported[0].id))
        XCTAssertEqual(study.noteType.css, ".prompt { font-size: 31px; }")
        let face = SpeechRenderer().face(study, side: .question, questionLocale: "en-US", answerLocale: "pt-BR")
        XCTAssertTrue(face.html.contains("Please."))
        XCTAssertTrue(face.html.contains("Say this in Brazilian Portuguese."))
        XCTAssertFalse(face.html.contains("Por favor."), "the Speak card asks in English")
    }

    /// A previous import (or a deck delete) can leave the same guid attached
    /// to the wrong note type, sometimes with no cards left. Replacing it
    /// must delete that note row; guid is unique.
    func testReimportReplacesNoteLeftOnTheWrongType() throws {
        let apkg = try portugueseSpeakPackage()
        let (db, decks, cards, reviews) = try makeStores()
        let home = try decks.create(fullName: "Old")
        let stale = try cards.createNote(
            fields: ["ptbr-001", "Por favor."], tags: [], deckID: home.id,
            noteTypeID: 1, guid: "ptv2"
        )
        try db.run("DELETE FROM cards WHERE note_id = ?", [.int(stale.id)])
        XCTAssertNotNil(try cards.note(guid: "ptv2"))

        let result = try ApkgImporter(decks: decks, cards: cards, reviews: reviews)
            .importPackage(zip: ZipReader(data: apkg))
        XCTAssertEqual(result.notesImported, 1)
        let imported = try XCTUnwrap(try cards.note(guid: "ptv2"))
        XCTAssertNotEqual(imported.noteTypeID, 1)
        let card = try XCTUnwrap(try cards.cards(forNote: imported.id).first)
        let study = try XCTUnwrap(try cards.studyCard(id: card.id))
        XCTAssertEqual(study.noteType.name, "Brazilian Portuguese - Everyday v2")
        XCTAssertEqual(study.card.templateOrdinal, 1)
    }

    private func portugueseSpeakPackage() throws -> Data {
        let ankiURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fixture-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: ankiURL) }
        let db = try SQLiteDatabase.open(url: ankiURL)
        for statement in [
            """
            CREATE TABLE col (
                id INTEGER PRIMARY KEY, crt INTEGER, mod INTEGER, scm INTEGER, ver INTEGER,
                dty INTEGER, usn INTEGER, ls INTEGER, conf TEXT,
                models TEXT, decks TEXT, dconf TEXT, tags TEXT
            );
            """,
            """
            CREATE TABLE notes (
                id INTEGER PRIMARY KEY, guid TEXT, mid INTEGER, mod INTEGER, usn INTEGER,
                tags TEXT, flds TEXT, sfld TEXT, csum INTEGER, flags INTEGER, data TEXT
            );
            """,
            """
            CREATE TABLE cards (
                id INTEGER PRIMARY KEY, nid INTEGER, did INTEGER, ord INTEGER,
                type INTEGER, queue INTEGER, due INTEGER, ivl INTEGER, factor INTEGER,
                reps INTEGER, lapses INTEGER, left INTEGER, odue INTEGER, odid INTEGER,
                flags INTEGER, data TEXT
            );
            """,
            "CREATE TABLE revlog (id INTEGER PRIMARY KEY, cid INTEGER, ease INTEGER, ivl INTEGER, lastIvl INTEGER, factor INTEGER, time INTEGER, type INTEGER);",
        ] { try db.execute(statement) }

        let models = """
        {"1892609201":{"id":"1892609201","name":"Brazilian Portuguese - Everyday v2","type":0,"css":".prompt { font-size: 31px; }","flds":[{"name":"ID"},{"name":"Portuguese"},{"name":"English"},{"name":"Cue"}],"tmpls":[{"name":"Understand","qfmt":"{{Portuguese}}","afmt":"{{English}}","ord":0},{"name":"Speak","qfmt":"{{English}}<div class=\\"cue\\">{{Cue}}</div>","afmt":"{{Portuguese}}","ord":1}]}}
        """
        let decks = #"{"2092609201":{"id":2092609201,"name":"Portuguese - Everyday"}}"#
        try db.run(
            "INSERT INTO col (crt, ver, models, decks, conf, dconf, tags) VALUES (?,?,?,?,?,?,?)",
            [.int(1_600_000_000), .int(11), .text(models), .text(decks), .text("{}"), .text("{}"), .text("")]
        )
        try db.run(
            "INSERT INTO notes (id, guid, mid, tags, flds, sfld, csum) VALUES (?,?,?,?,?,?,0)",
            [.int(10), .text("ptv2"), .int(1_892_609_201), .text("pt_br"),
             .text("ptbr-001\u{1f}Por favor.\u{1f}Please.\u{1f}Say this in Brazilian Portuguese."), .text("Por favor.")]
        )
        try db.run(
            "INSERT INTO cards (id, nid, did, ord, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [.int(20), .int(10), .int(2_092_609_201), .int(1), .int(0), .int(0), .int(1),
             .int(0), .int(0), .int(0), .int(0), .int(0), .int(0), .int(0), .int(0), .text("")]
        )
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.execute("PRAGMA journal_mode=DELETE")
        var writer = ZipWriter()
        writer.add(name: "collection.anki2", data: try Data(contentsOf: ankiURL))
        writer.add(name: "media", data: Data("{}".utf8))
        return writer.finalize()
    }

    func testMediaFilenameParsing() {
        XCTAssertEqual(
            ApkgExporter.mediaFilenames(in: ["[sound:foo.mp3]", #"<img src="bar.jpg">"#]),
            ["foo.mp3", "bar.jpg"]
        )
        XCTAssertEqual(
            ApkgExporter.mediaFilenames(in: [#"<img src="https://example.com/x.png">"#]),
            []
        )
    }
}
