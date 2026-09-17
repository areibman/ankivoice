import Foundation

/// CRUD, search, and scheduling updates for cards and notes.
public final class CardRepository: @unchecked Sendable {
    let db: SQLiteDatabase

    public init(db: SQLiteDatabase) { self.db = db }

    // MARK: - Note types

    public func noteType(id: Int64) throws -> NoteType? {
        try db.query("SELECT id, name, field_names, templates, kind FROM note_types WHERE id = ?", [.int(id)]) {
            Self.rowToNoteType($0)
        }.first
    }

    public func noteType(named name: String) throws -> NoteType? {
        try db.query("SELECT id, name, field_names, templates, kind FROM note_types WHERE name = ?", [.text(name)]) {
            Self.rowToNoteType($0)
        }.first
    }

    static func rowToNoteType(_ r: Row) -> NoteType {
        NoteType(
            id: r.int(0),
            name: r.string(1),
            fieldNames: decodeJSON([String].self, r.string(2)) ?? [],
            templates: decodeJSON([NoteTemplate].self, r.string(3)) ?? [],
            kind: NoteTypeKind(rawValue: r.int32(4)) ?? .standard
        )
    }

    @discardableResult
    public func upsertNoteType(_ type: NoteType) throws -> Int64 {
        if let existing = try noteType(id: type.id) ?? noteType(named: type.name) {
            try db.run(
                "UPDATE note_types SET name = ?, field_names = ?, templates = ?, kind = ? WHERE id = ?",
                [.text(type.name), .json(type.fieldNames), .json(type.templates),
                 .int(Int64(type.kind.rawValue)), .int(existing.id)]
            )
            return existing.id
        }
        return try db.run(
            "INSERT INTO note_types (id, name, field_names, templates, kind) VALUES (?,?,?,?,?)",
            [.int(type.id), .text(type.name), .json(type.fieldNames), .json(type.templates),
             .int(Int64(type.kind.rawValue))]
        )
    }

    // MARK: - Note + card creation

    /// Creates a note with `fields` and one card per template of its note type.
    @discardableResult
    public func createNote(
        fields: [String], tags: [String] = [], deckID: Int64,
        noteTypeID: Int64 = 1, guid: String? = nil
    ) throws -> Note {
        try db.transaction {
            let now = Date()
            let noteID = try db.run(
                "INSERT INTO notes (note_type_id, fields, tags, guid, created_at, modified_at) VALUES (?,?,?,?,?,?)",
                [.int(noteTypeID), .json(fields), .text(tags.joined(separator: " ")),
                 .text(guid ?? UUID().uuidString), .date(now), .date(now)]
            )
            let templateCount: Int
            if let nt = try noteType(id: noteTypeID) {
                templateCount = max(1, nt.templates.count)
            } else {
                templateCount = 1
            }
            for ordinal in 0..<templateCount {
                _ = try db.run(
                    """
                    INSERT INTO cards (note_id, deck_id, template_ordinal, state, due, created_at, modified_at)
                    VALUES (?,?,?,0,?,?,?)
                    """,
                    [.int(noteID), .int(deckID), .int(Int64(ordinal)), .date(now), .date(now), .date(now)]
                )
            }
            return Note(id: noteID, noteTypeID: noteTypeID, fields: fields, tags: tags,
                        guid: guid ?? "", createdAt: now, modifiedAt: now)
        }
    }

    static func rowToNote(_ r: Row) -> Note {
        Note(
            id: r.int(0),
            noteTypeID: r.int(1),
            fields: decodeJSON([String].self, r.string(2)) ?? [],
            tags: r.string(3).split(separator: " ").map(String.init),
            guid: r.string(4),
            createdAt: r.date(5),
            modifiedAt: r.date(6)
        )
    }

    public func note(id: Int64) throws -> Note? {
        try db.query(
            "SELECT id, note_type_id, fields, tags, guid, created_at, modified_at FROM notes WHERE id = ?",
            [.int(id)]
        ) { Self.rowToNote($0) }.first
    }

    /// Finds a note by its stable guid (used by import deduplication).
    public func note(guid: String) throws -> Note? {
        try db.query(
            "SELECT id, note_type_id, fields, tags, guid, created_at, modified_at FROM notes WHERE guid = ?",
            [.text(guid)]
        ) { Self.rowToNote($0) }.first
    }

    /// Updates note content and, when the card count changes, reconciles cards.
    public func updateNote(id: Int64, fields: [String], tags: [String]) throws {
        let now = Date()
        try db.run(
            "UPDATE notes SET fields = ?, tags = ?, modified_at = ? WHERE id = ?",
            [.json(fields), .text(tags.joined(separator: " ")), .date(now), .int(id)]
        )
        // Keep card ordinals consistent with the note type's template count.
        if let note = try note(id: id), let nt = try noteType(id: note.noteTypeID) {
            let ordinals = try db.query(
                "SELECT id, template_ordinal FROM cards WHERE note_id = ?", [.int(id)]
            ) { (id: $0.int(0), ordinal: $0.int32(1)) }
            let existing = Set(ordinals.map(\.ordinal))
            for ordinal in 0..<max(1, nt.templates.count) where !existing.contains(ordinal) {
                _ = try db.run(
                    """
                    INSERT INTO cards (note_id, deck_id, template_ordinal, state, due, created_at, modified_at)
                    SELECT note_id, deck_id, ?, 0, ?, ?, ? FROM cards WHERE note_id = ? LIMIT 1
                    """,
                    [.int(Int64(ordinal)), .date(now), .date(now), .date(now), .int(id)]
                )
            }
        }
    }

    // MARK: - Cards

    static let cardSelect = """
        SELECT c.id, c.note_id, c.deck_id, c.template_ordinal, c.state, c.step, c.due,
               c.stability, c.difficulty, c.last_review, c.lapses, c.reps, c.suspended,
               c.created_at, c.modified_at
        FROM cards c
        """

    /// Full joined select producing `StudyCard` rows (card + note + note type + deck).
    static let studyCardSQL = """
        SELECT c.id, c.note_id, c.deck_id, c.template_ordinal, c.state, c.step, c.due,
               c.stability, c.difficulty, c.last_review, c.lapses, c.reps, c.suspended,
               c.created_at, c.modified_at,
               n.note_type_id, n.fields, n.tags, n.guid, n.created_at, n.modified_at,
               t.name, t.field_names, t.templates, t.kind,
               d.name, d.full_name, d.parent_id, d.created_at, d.modified_at
        FROM cards c
        JOIN notes n ON n.id = c.note_id
        JOIN note_types t ON t.id = n.note_type_id
        JOIN decks d ON d.id = c.deck_id
        """

    static func rowToCard(_ r: Row) -> Card {
        Card(
            id: r.int(0),
            noteID: r.int(1),
            deckID: r.int(2),
            templateOrdinal: r.int32(3),
            scheduling: SchedulingState(
                kind: CardStateKind(rawValue: r.int32(4)) ?? .new,
                step: r.isNull(5) ? nil : r.int32(5),
                stability: r.doubleOrNil(7),
                difficulty: r.doubleOrNil(8),
                due: r.date(6),
                lastReview: r.dateOrNil(9),
                lapses: r.int32(10),
                reps: r.int32(11)
            ),
            suspended: r.int(12) != 0,
            createdAt: r.date(13),
            modifiedAt: r.date(14)
        )
    }

    static func rowToStudyCard(_ r: Row) -> StudyCard {
        StudyCard(
            card: rowToCard(r),
            note: Note(
                id: r.int(1),
                noteTypeID: r.int(15),
                fields: decodeJSON([String].self, r.string(16)) ?? [],
                tags: r.string(17).split(separator: " ").map(String.init),
                guid: r.string(18),
                createdAt: r.date(19),
                modifiedAt: r.date(20)
            ),
            noteType: NoteType(
                id: r.int(15),
                name: r.string(21),
                fieldNames: decodeJSON([String].self, r.string(22)) ?? [],
                templates: decodeJSON([NoteTemplate].self, r.string(23)) ?? [],
                kind: NoteTypeKind(rawValue: r.int32(24)) ?? .standard
            ),
            deck: Deck(
                id: r.int(2),
                name: r.string(25),
                fullName: r.string(26),
                parentID: r.isNull(27) ? nil : r.int(27),
                createdAt: r.date(28),
                modifiedAt: r.date(29)
            )
        )
    }

    public func card(id: Int64) throws -> Card? {
        try db.query("\(Self.cardSelect) WHERE c.id = ?", [.int(id)]) { Self.rowToCard($0) }.first
    }

    /// All cards generated from one note, in template order.
    public func cards(forNote noteID: Int64) throws -> [Card] {
        try db.query(
            "\(Self.cardSelect) WHERE c.note_id = ? ORDER BY c.template_ordinal", [.int(noteID)]
        ) { Self.rowToCard($0) }
    }

    public func cards(inDeck deckID: Int64, includingChildren: Bool = false) throws -> [Card] {
        if includingChildren {
            let deckIDs = try descendantDeckIDs(including: deckID)
            let placeholders = deckIDs.map { _ in "?" }.joined(separator: ",")
            return try db.query(
                "\(Self.cardSelect) WHERE c.deck_id IN (\(placeholders)) ORDER BY c.id",
                deckIDs.map { .int($0) }
            ) { Self.rowToCard($0) }
        }
        return try db.query(
            "\(Self.cardSelect) WHERE c.deck_id = ? ORDER BY c.id", [.int(deckID)]
        ) { Self.rowToCard($0) }
    }

    public func descendantDeckIDs(including root: Int64) throws -> [Int64] {
        var result: [Int64] = [root]
        var frontier = [root]
        while let next = frontier.popLast() {
            let children = try db.query("SELECT id FROM decks WHERE parent_id = ?", [.int(next)]) { $0.int(0) }
            result.append(contentsOf: children)
            frontier.append(contentsOf: children)
        }
        return result
    }

    public func search(query: String, deckID: Int64? = nil, limit: Int = 500) throws -> [StudyCard] {
        let pattern = "%\(query.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
        var sql = """
        \(Self.studyCardSQL)
        WHERE (n.fields LIKE ? ESCAPE '\\' OR n.tags LIKE ? ESCAPE '\\')
        """
        var binds: [SQLiteValue] = [.text(pattern), .text(pattern)]
        if let deckID {
            let ids = try descendantDeckIDs(including: deckID)
            sql += " AND c.deck_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            binds.append(contentsOf: ids.map { .int($0) })
        }
        sql += " ORDER BY n.modified_at DESC LIMIT \(limit)"
        return try db.query(sql, binds) { Self.rowToStudyCard($0) }
    }

    public func studyCard(id: Int64) throws -> StudyCard? {
        try db.query("\(Self.studyCardSQL) WHERE c.id = ?", [.int(id)]) {
            Self.rowToStudyCard($0)
        }.first
    }

    public func updateScheduling(_ card: Card) throws {
        try db.run(
            """
            UPDATE cards SET state = ?, step = ?, due = ?, stability = ?, difficulty = ?,
                last_review = ?, lapses = ?, reps = ?, suspended = ?, modified_at = ?
            WHERE id = ?
            """,
            [
                .int(Int64(card.scheduling.kind.rawValue)),
                .optionalInt(card.scheduling.step),
                .date(card.scheduling.due),
                .optionalDouble(card.scheduling.stability),
                .optionalDouble(card.scheduling.difficulty),
                .optionalDate(card.scheduling.lastReview),
                .int(Int64(card.scheduling.lapses)),
                .int(Int64(card.scheduling.reps)),
                .bool(card.suspended),
                .date(card.modifiedAt),
                .int(card.id),
            ]
        )
    }

    public func setSuspended(_ suspended: Bool, cardID: Int64) throws {
        try db.run(
            "UPDATE cards SET suspended = ?, modified_at = ? WHERE id = ?",
            [.bool(suspended), .date(Date()), .int(cardID)]
        )
    }

    public func moveCard(_ cardID: Int64, toDeck deckID: Int64) throws {
        try db.run(
            "UPDATE cards SET deck_id = ?, modified_at = ? WHERE id = ?",
            [.int(deckID), .date(Date()), .int(cardID)]
        )
    }

    public func deleteCard(_ cardID: Int64) throws {
        try db.run("DELETE FROM reviews WHERE card_id = ?", [.int(cardID)])
        try db.run("DELETE FROM cards WHERE id = ?", [.int(cardID)])
        _ = try db.runUpdate("DELETE FROM notes WHERE id NOT IN (SELECT DISTINCT note_id FROM cards)")
    }

    /// Directly sets scheduling state — used by import and undo restore.
    public func replaceScheduling(_ scheduling: SchedulingState, cardID: Int64) throws {
        try db.run(
            """
            UPDATE cards SET state = ?, step = ?, due = ?, stability = ?, difficulty = ?,
                last_review = ?, lapses = ?, reps = ?, modified_at = ?
            WHERE id = ?
            """,
            [
                .int(Int64(scheduling.kind.rawValue)),
                .optionalInt(scheduling.step),
                .date(scheduling.due),
                .optionalDouble(scheduling.stability),
                .optionalDouble(scheduling.difficulty),
                .optionalDate(scheduling.lastReview),
                .int(Int64(scheduling.lapses)),
                .int(Int64(scheduling.reps)),
                .date(Date()),
                .int(cardID),
            ]
        )
    }

    // MARK: - Counts

    public struct DeckCounts: Sendable, Equatable {
        public var newCards = 0
        public var learning = 0
        public var due = 0
        public var total = 0
        public var suspended = 0
    }

    /// Card counts for a deck (including descendant decks).
    public func counts(forDeck deckID: Int64, at now: Date = Date()) throws -> DeckCounts {
        let ids = try descendantDeckIDs(including: deckID)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var counts = DeckCounts()
        let dueSeconds = now.timeIntervalSince1970
        let rows = try db.query(
            "SELECT state, suspended, due FROM cards WHERE deck_id IN (\(placeholders))",
            ids.map { .int($0) }
        ) { (state: $0.int32(0), suspended: $0.int(1) != 0, due: $0.double(2)) }
        counts.total = rows.count
        for row in rows where !row.suspended {
            switch row.state {
            case 0: counts.newCards += 1
            case 1, 3: if row.due <= dueSeconds { counts.learning += 1 }
            case 2: if row.due <= dueSeconds { counts.due += 1 }
            default: break
            }
        }
        counts.suspended = rows.filter(\.suspended).count
        return counts
    }
}

// MARK: - SQLiteValue JSON helpers

extension SQLiteValue {
    static func json<T: Encodable>(_ value: T) -> SQLiteValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return .null }
        return .text(String(decoding: data, as: UTF8.self))
    }
}
