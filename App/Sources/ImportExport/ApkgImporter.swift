import Foundation

/// Anki `.apkg` import (PRD §27).
///
/// An `.apkg` is a ZIP containing `collection.anki2` (a SQLite database),
/// a `media` file (JSON mapping numeric names → filenames), and the media
/// files themselves under numeric names.
///
/// Preserved: deck hierarchy, note types (incl. cloze), notes, tags, cards,
/// review history, FSRS memory state when present, media, suspension.
/// When FSRS state is absent but review history exists, the card is
/// rescheduled by replaying its history through FSRS.
public struct ApkgImporter: Sendable {

    public struct Result: Sendable, Equatable {
        public var deckID: Int64
        public var notesImported = 0
        public var cardsImported = 0
        public var reviewsImported = 0
        public var mediaImported = 0
        public var warnings: [String] = []
    }

    // Anki JSON payload shapes
    private struct AnkiDeck: Decodable {
        let id: Int64
        let name: String
    }

    private struct AnkiField: Decodable {
        let name: String
    }

    private struct AnkiTemplate: Decodable {
        let name: String?
        let qfmt: String?
        let afmt: String?
        let ord: Int?
    }

    private struct AnkiModel: Decodable {
        let id: Int64
        let name: String?
        let type: Int?
        let flds: [AnkiField]?
        let tmpls: [AnkiTemplate]?
    }

    private struct AnkiCol: Decodable {
        let crt: Double?
        let decks: [AnkiDeck]?
        let models: [String: AnkiModel]?
    }

    /// One Anki `cards` table row.
    typealias AnkiCardRow = (
        id: Int64, nid: Int64, did: Int64, ord: Int, type: Int, queue: Int,
        due: Double, ivl: Int, factor: Int, reps: Int, lapses: Int, data: String
    )

    private let decks: DeckRepository
    private let cardsRepo: CardRepository
    private let reviewsRepo: ReviewRepository

    public init(decks: DeckRepository, cards: CardRepository, reviews: ReviewRepository) {
        self.decks = decks
        self.cardsRepo = cards
        self.reviewsRepo = reviews
    }

    // MARK: - Import

    /// Progress callback: `fraction` runs 0…1 across the whole import.
    public typealias ProgressHandler = @Sendable (_ fraction: Double, _ message: String) -> Void

    public func importPackage(
        at url: URL,
        scheduler: FSRSScheduler = FSRSScheduler(),
        progress: ProgressHandler? = nil
    ) throws -> Result {
        let zip = try ZipReader(url: url)
        return try importPackage(zip: zip, scheduler: scheduler, progress: progress)
    }

    /// Picks the collection database inside a package.
    ///
    /// Anki 2.1 exports ship the real collection as `collection.anki21` next
    /// to a one-note `collection.anki2` stub that just says "upgrade Anki", so
    /// the newer file wins. `collection.anki21b` (Anki ≥ 2.1.50 without
    /// "support older versions") is zstd-compressed and unreadable here.
    static func collectionEntryName(in zip: ZipReader) throws -> String {
        if zip.entry(named: "collection.anki21b") != nil {
            throw ZipReader.ZipError.unsupportedMethod(method: 93, entry: "collection.anki21b")
        }
        if let name = ["collection.anki21", "collection.anki2"].first(where: { zip.entry(named: $0) != nil }) {
            return name
        }
        if zip.entries.contains(where: { $0.name.hasPrefix("collection.") }) {
            throw ZipReader.ZipError.unsupportedMethod(method: 93, entry: "collection.*")
        }
        throw ZipReader.ZipError.entryNotFound("collection.anki2")
    }

    public func importPackage(
        zip: ZipReader,
        scheduler: FSRSScheduler = FSRSScheduler(),
        progress: ProgressHandler? = nil
    ) throws -> Result {
        var result = Result(deckID: 0)
        progress?(0, "Reading package…")

        // Materialize the collection into a temporary file — SQLite needs a
        // real file, and streaming keeps memory flat for big decks.
        let dbName = try Self.collectionEntryName(in: zip)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try zip.extract(dbName, to: tempURL)

        let anki = try SQLiteDatabase.open(url: tempURL, readOnly: true)

        let col = try readCollection(anki)
        let crt = col.crt ?? Date(timeIntervalSince1970: 0).timeIntervalSince1970

        // 1. Note types.
        var noteTypeIDMap: [Int64: Int64] = [:]
        for (_, model) in (col.models ?? [:]).sorted(by: { $0.key < $1.key }) {
            let fields = (model.flds ?? []).map(\.name)
            let templates = (model.tmpls ?? []).enumerated().map { index, tmpl in
                NoteTemplate(
                    name: tmpl.name ?? "Card \(index + 1)",
                    questionFormat: tmpl.qfmt ?? "{{Front}}",
                    answerFormat: tmpl.afmt ?? "{{FrontSide}}<hr>{{Back}}",
                    ordinal: tmpl.ord ?? index
                )
            }
            let kind: NoteTypeKind = (model.type ?? 0) == 1 ? .cloze : .standard
            let localID = try cardsRepo.upsertNoteType(
                NoteType(id: model.id, name: model.name ?? "Type \(model.id)",
                         fieldNames: fields.isEmpty ? ["Front", "Back"] : fields,
                         templates: templates.isEmpty
                            ? NoteType.basic.templates : templates,
                         kind: kind)
            )
            noteTypeIDMap[model.id] = localID
        }

        // 2. Decks (hierarchy via :: names).
        var deckIDMap: [Int64: Int64] = [:]
        for deck in col.decks ?? [] where deck.id > 0 && deck.name != "Default" {
            let trimmed = deck.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let local = try decks.create(fullName: trimmed)
            deckIDMap[deck.id] = local.id
        }
        let defaultDeck = try decks.create(fullName: "Default")
        deckIDMap[1_4253_68048_6497] = defaultDeck.id  // Anki's default deck id

        // 3. Notes + cards + revlog.
        let notes = try anki.query("SELECT id, guid, mid, tags, flds, mod FROM notes") {
            (id: $0.int(0), guid: $0.string(1), mid: $0.int(2), tags: $0.string(3), flds: $0.string(4), mod: $0.double(5))
        }
        let ankiCards: [AnkiCardRow] = try anki.query(
            "SELECT id, nid, did, ord, type, queue, due, ivl, factor, reps, lapses, data FROM cards"
        ) { row -> AnkiCardRow in
            AnkiCardRow(
                id: row.int(0), nid: row.int(1), did: row.int(2), ord: row.int32(3),
                type: row.int32(4), queue: row.int32(5), due: row.double(6), ivl: row.int32(7),
                factor: row.int32(8), reps: row.int32(9), lapses: row.int32(10), data: row.string(11)
            )
        }
        let revlog = try anki.query("SELECT id, cid, ease, time, type FROM revlog ORDER BY id ASC") {
            (id: $0.int(0), cid: $0.int(1), ease: $0.int32(2), timeMs: $0.int32(3), type: $0.int32(4))
        }
        var revlogByCard: [Int64: [(at: Date, rating: Rating, timeMs: Int)]] = [:]
        for entry in revlog where entry.type != 4 {  // type 4 = manual reset
            guard let rating = Rating(rawValue: entry.ease) else { continue }
            let at = Date(timeIntervalSince1970: Double(entry.id) / 1000.0)
            revlogByCard[entry.cid, default: []].append((at, rating, entry.timeMs))
        }

        // Cards grouped by note, in template order.
        var cardsByNote: [Int64: [AnkiCardRow]] = [:]
        for card in ankiCards { cardsByNote[card.nid, default: []].append(card) }
        for key in cardsByNote.keys { cardsByNote[key]?.sort { $0.ord < $1.ord } }

        // Notes are written in batches, each in its own transaction: one
        // commit per batch instead of per row, while the main thread can
        // still get at the database between batches.
        let batchSize = 200
        let totalNotes = max(notes.count, 1)
        var processed = 0
        for batchStart in stride(from: 0, to: notes.count, by: batchSize) {
            let batch = notes[batchStart..<min(batchStart + batchSize, notes.count)]
            try cardsRepo.db.transaction {
                for note in batch {
                    try importNote(
                        note, cardsByNote: cardsByNote, revlogByCard: revlogByCard,
                        noteTypeIDMap: noteTypeIDMap, deckIDMap: deckIDMap, defaultDeck: defaultDeck,
                        crt: crt, scheduler: scheduler, result: &result
                    )
                }
            }
            processed += batch.count
            progress?(0.1 + 0.7 * Double(processed) / Double(totalNotes), "Importing cards…")
        }

        // 4. Media, streamed file by file.
        if let mediaEntry = zip.entry(named: "media") {
            let mediaData = try zip.extract(mediaEntry)
            if let mapping = try? JSONDecoder().decode([String: String].self, from: mediaData) {
                let mediaDir = try AppServices.mediaDirectory()
                let total = max(mapping.count, 1)
                for (index, (numeric, filename)) in mapping.enumerated() {
                    let sanitized = filename.replacingOccurrences(of: "/", with: "_")
                    guard !sanitized.isEmpty, let entry = zip.entry(named: numeric) else { continue }
                    let destination = mediaDir.appendingPathComponent(sanitized)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        do {
                            try zip.extract(entry, to: destination)
                            result.mediaImported += 1
                        } catch {
                            result.warnings.append("Couldn't extract media file \(filename).")
                        }
                    }
                    if index % 50 == 0 {
                        progress?(0.8 + 0.2 * Double(index) / Double(total), "Copying media…")
                    }
                }
            }
        }

        progress?(1, "Done")
        result.deckID = defaultDeck.id
        return result
    }

    private typealias AnkiNoteRow = (id: Int64, guid: String, mid: Int64, tags: String, flds: String, mod: Double)

    /// Imports one note with its cards, scheduling and review history.
    private func importNote(
        _ note: AnkiNoteRow,
        cardsByNote: [Int64: [AnkiCardRow]],
        revlogByCard: [Int64: [(at: Date, rating: Rating, timeMs: Int)]],
        noteTypeIDMap: [Int64: Int64],
        deckIDMap: [Int64: Int64],
        defaultDeck: Deck,
        crt: Double,
        scheduler: FSRSScheduler,
        result: inout Result
    ) throws {
        let fields = note.flds.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard !fields.isEmpty else { return }
        let tags = note.tags.split(separator: " ").map(String.init).filter { $0 != "" }
        let localTypeID = noteTypeIDMap[note.mid] ?? 1

        // Skip notes already present (same guid).
        if try cardsRepo.note(guid: note.guid) != nil { return }

        let noteCards = cardsByNote[note.id] ?? []
        guard let firstCard = noteCards.first else {
            // Note with no cards: import as a plain basic note into Default.
            _ = try cardsRepo.createNote(
                fields: [fields.first ?? "", fields.count > 1 ? fields[1] : ""],
                tags: tags, deckID: defaultDeck.id, noteTypeID: 1, guid: note.guid
            )
            result.notesImported += 1
            return
        }

        let deckID = deckIDMap[firstCard.did] ?? defaultDeck.id
        let created = try cardsRepo.createNote(
            fields: fields, tags: tags, deckID: deckID,
            noteTypeID: localTypeID, guid: note.guid
        )
        result.notesImported += 1

        // Reconcile card count with ordinals and apply scheduling.
        let localCards = try cardsRepo.cards(forNote: created.id)
        for ankiCard in noteCards {
            guard let local = localCards.first(where: { $0.templateOrdinal == ankiCard.ord })
                    ?? (localCards.indices.contains(ankiCard.ord) ? localCards[ankiCard.ord] : nil) else { continue }
            let entries = revlogByCard[ankiCard.id] ?? []
            let (scheduling, _) = try mapScheduling(
                ankiCard: ankiCard, revlog: entries, crt: crt, scheduler: scheduler
            )
            try cardsRepo.replaceScheduling(scheduling, cardID: local.id)
            if ankiCard.queue == -1 {
                try cardsRepo.setSuspended(true, cardID: local.id)
            }
            if ankiCard.did != firstCard.did, let cardDeck = deckIDMap[ankiCard.did] {
                try cardsRepo.moveCard(local.id, toDeck: cardDeck)
            }
            result.cardsImported += 1

            // Review history (best-effort; capped to keep imports fast).
            if !entries.isEmpty {
                var previous = SchedulingState()
                for entry in entries.prefix(2000) {
                    let replayed = scheduler.review(previous.memoryState, rating: entry.rating, at: entry.at)
                    let log = ReviewLog(
                        id: 0, cardID: local.id, rating: entry.rating, reviewedAt: entry.at,
                        durationMs: max(0, entry.timeMs), studyMode: .touch,
                        previousState: previous, newState: SchedulingState(memory: replayed.state)
                    )
                    _ = try reviewsRepo.append(log)
                    previous = SchedulingState(memory: replayed.state)
                    result.reviewsImported += 1
                }
            }
        }
    }

    // MARK: - Scheduling translation

    /// Maps one Anki card row into our scheduling state.
    private func mapScheduling(
        ankiCard: AnkiCardRow,
        revlog: [(at: Date, rating: Rating, timeMs: Int)],
        crt: Double,
        scheduler: FSRSScheduler
    ) throws -> (SchedulingState, Int) {
        // FSRS memory state stored by modern Anki (cards.data JSON).
        if let jsonData = ankiCard.data.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let s = parsed["s"] as? Double, let d = parsed["d"] as? Double {
            let kind: CardStateKind
            var dueDate: Date
            switch ankiCard.type {
            case 0: kind = .new; dueDate = Date()
            case 1, 3: kind = ankiCard.type == 3 ? .relearning : .learning; dueDate = Date(timeIntervalSince1970: ankiCard.due)
            default: kind = .review; dueDate = Date(timeIntervalSince1970: crt + ankiCard.due * 86_400)
            }
            var state = SchedulingState(
                kind: kind,
                step: (kind == .learning || kind == .relearning) ? 0 : nil,
                stability: s, difficulty: d,
                due: dueDate,
                lastReview: revlog.last?.at,
                lapses: Int(ankiCard.lapses), reps: Int(ankiCard.reps)
            )
            if kind == .new { state.stability = nil; state.difficulty = nil }
            return (state, revlog.count)
        }

        // Review history present: reschedule by replaying (Anki's
        // "compute memory state from history" equivalent).
        if !revlog.isEmpty {
            let ratings = revlog.map { (rating: $0.rating, at: $0.at) }
            let replayed = scheduler.reschedule(ratings: ratings)
            return (SchedulingState(memory: replayed), revlog.count)
        }

        // Fall back to mapping Anki's scheduler state directly.
        var state = SchedulingState(
            lapses: Int(ankiCard.lapses), reps: Int(ankiCard.reps)
        )
        switch ankiCard.queue {
        case -1, -2, -3:  // suspended / buried
            fallthrough
        case 0:  // new
            state.kind = .new
            state.due = Date()
        case 1:  // learning
            state.kind = .learning
            state.step = 0
            state.due = Date(timeIntervalSince1970: ankiCard.due)
        case 2:  // review
            state.kind = .review
            state.due = Date(timeIntervalSince1970: crt + ankiCard.due * 86_400)
            // Derive approximate memory state from interval and ease.
            let interval = max(1, ankiCard.ivl)
            state.stability = Double(interval)
            state.difficulty = 5.0
        case 3:  // day-learning
            state.kind = .learning
            state.step = 0
            state.due = Date(timeIntervalSince1970: crt + ankiCard.due * 86_400)
        default:
            state.kind = .new
        }
        return (state, revlog.count)
    }

    // MARK: - Collection parsing

    private func readCollection(_ db: SQLiteDatabase) throws -> AnkiCol {
        struct ColRow: Decodable {
            let crt: Double?
            let decks: String?
            let models: String?
        }
        let rows = try db.query("SELECT crt, decks, models FROM col LIMIT 1") {
            (crt: $0.doubleOrNil(0), decks: $0.stringOrNil(1), models: $0.stringOrNil(2))
        }
        guard let row = rows.first else {
            throw ZipReader.ZipError.corruptEntry("collection.anki2")
        }
        let decoder = JSONDecoder()

        func parseDecks(_ json: String?) -> [AnkiDeck]? {
            guard let data = json?.data(using: .utf8) else { return nil }
            // Anki stores decks as an array (schema 11) or object map (older).
            if let array = try? decoder.decode([AnkiDeck].self, from: data) {
                return array
            }
            if let dict = try? decoder.decode([String: AnkiDeck].self, from: data) {
                return Array(dict.values)
            }
            return nil
        }

        func parseModels(_ json: String?) -> [String: AnkiModel]? {
            guard let data = json?.data(using: .utf8) else { return nil }
            if let dict = try? decoder.decode([String: AnkiModel].self, from: data) {
                return dict
            }
            if let array = try? decoder.decode([AnkiModel].self, from: data) {
                return Dictionary(uniqueKeysWithValues: array.map { (String($0.id), $0) })
            }
            return nil
        }

        return AnkiCol(
            crt: row.crt,
            decks: parseDecks(row.decks),
            models: parseModels(row.models)
        )
    }
}
