import Foundation

/// CRUD and queries for decks, including study/voice configuration.
public final class DeckRepository: @unchecked Sendable {
    let db: SQLiteDatabase

    public init(db: SQLiteDatabase) { self.db = db }

    // MARK: Mapping

    static func rowToDeck(_ r: Row) -> Deck {
        Deck(
            id: r.int(0),
            name: r.string(1),
            fullName: r.string(2),
            parentID: r.isNull(3) ? nil : r.int(3),
            createdAt: r.date(4),
            modifiedAt: r.date(5),
            kind: DeckKind(rawValue: r.int32(17)) ?? .normal
        )
    }

    static let deckColumns = """
        id, name, full_name, parent_id, created_at, modified_at,
        new_per_day, reviews_per_day, desired_retention, maximum_interval_days,
        question_locale, answer_locale, question_voice, answer_voice,
        speech_rate, last_studied_at, use_default_speech_rate,
        kind, bury_new, bury_reviews, bury_interday, filter_query, filter_limit,
        filter_order, reschedule, fsrs_parameters, easy_days, learn_steps, relearn_steps
        """

    static func config(from r: Row) -> (study: StudyConfig, voice: VoiceConfig, lastStudied: Date?) {
        let study = StudyConfig(
            newPerDay: r.int32(6),
            reviewsPerDay: r.int32(7),
            desiredRetention: r.double(8),
            maximumIntervalDays: r.int32(9),
            buryNewSiblings: r.int(18) != 0,
            buryReviewSiblings: r.int(19) != 0,
            buryInterdayLearning: r.int(20) != 0,
            parameters: r.stringOrNil(25).flatMap { decodeJSON([Double].self, $0) },
            easyDays: r.stringOrNil(26).flatMap { decodeJSON([Double].self, $0) } ?? [1, 1, 1, 1, 1, 1, 1],
            learningSteps: r.stringOrNil(27).flatMap { decodeJSON([Double].self, $0) } ?? [60, 600],
            relearningSteps: r.stringOrNil(28).flatMap { decodeJSON([Double].self, $0) } ?? [600]
        )
        let voice = VoiceConfig(
            questionLocale: r.string(10),
            answerLocale: r.string(11),
            questionVoice: r.stringOrNil(12),
            answerVoice: r.stringOrNil(13),
            speechRate: r.double(14),
            usesDefaultSpeechRate: r.int(16) != 0
        )
        return (study, voice, r.dateOrNil(15))
    }

    // MARK: CRUD

    /// Creates a deck (and any missing ancestors implied by a `::`-separated full name).
    @discardableResult
    public func create(fullName: String) throws -> Deck {
        try db.transaction {
            let parts = fullName.split(separator: Deck.nameSeparator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            precondition(!parts.isEmpty, "deck name must not be empty")

            var parentID: Int64? = nil
            var created: Deck? = nil
            var path: [String] = []
            for part in parts {
                path.append(part)
                let full = path.joined(separator: Deck.nameSeparator)
                if let existing = try deck(named: full) {
                    parentID = existing.id
                    created = existing
                    continue
                }
                let now = Date()
                let parent = parentID
                let id = try db.run(
                    "INSERT INTO decks (name, full_name, parent_id, created_at, modified_at) VALUES (?,?,?,?,?)",
                    [.text(part), .text(full), .optionalInt(parent.map(Int.init)), .date(now), .date(now)]
                )
                parentID = id
                created = Deck(id: id, name: part, fullName: full, parentID: parent, createdAt: now, modifiedAt: now)
            }
            return created!
        }
    }

    public func deck(named fullName: String) throws -> Deck? {
        try db.query(
            "SELECT \(Self.deckColumns) FROM decks WHERE full_name = ?",
            [.text(fullName)]
        ) { Self.rowToDeck($0) }.first
    }

    public func deck(id: Int64) throws -> Deck? {
        try db.query(
            "SELECT \(Self.deckColumns) FROM decks WHERE id = ?",
            [.int(id)]
        ) { Self.rowToDeck($0) }.first
    }

    public func all() throws -> [Deck] {
        try db.query("SELECT \(Self.deckColumns) FROM decks ORDER BY full_name") { Self.rowToDeck($0) }
    }

    public func rename(_ id: Int64, to newFullName: String) throws {
        guard let deck = try deck(id: id) else { return }
        let parts = newFullName.split(separator: Deck.nameSeparator).map(String.init)
        guard let last = parts.last, !last.isEmpty else { return }
        let now = Date()
        try db.run(
            "UPDATE decks SET name = ?, full_name = ?, modified_at = ? WHERE id = ?",
            [.text(last), .text(newFullName), .date(now), .int(id)]
        )
        // Update descendants' full names.
        let prefix = deck.fullName + Deck.nameSeparator
        for child in try db.query(
            "SELECT id, full_name FROM decks WHERE full_name LIKE ?",
            [.text(prefix + "%")]
        ) { (id: $0.int(0), fullName: $0.string(1)) } {
            let updated = newFullName + Deck.nameSeparator + String(child.fullName.dropFirst(prefix.count))
            try db.run(
                "UPDATE decks SET full_name = ?, modified_at = ? WHERE id = ?",
                [.text(updated), .date(now), .int(child.id)]
            )
        }
    }

    /// Deletes a deck and all of its cards (notes are kept — they may be shared).
    public func delete(_ id: Int64) throws {
        try db.transaction {
            // Collect descendant ids.
            var ids: [Int64] = [id]
            var frontier = [id]
            while let next = frontier.popLast() {
                let children = try db.query(
                    "SELECT id FROM decks WHERE parent_id = ?", [.int(next)]
                ) { $0.int(0) }
                ids.append(contentsOf: children)
                frontier.append(contentsOf: children)
            }
            for did in ids {
                try db.run(
                    """
                    UPDATE cards SET deck_id = original_deck_id, original_deck_id = NULL,
                        filter_position = NULL
                    WHERE deck_id = ? AND original_deck_id IS NOT NULL
                    """,
                    [.int(did)]
                )
                try db.run("DELETE FROM cards WHERE deck_id = ?", [.int(did)])
                try db.run("DELETE FROM decks WHERE id = ?", [.int(did)])
            }
        }
    }

    // MARK: Configuration

    public func config(for id: Int64) throws -> (study: StudyConfig, voice: VoiceConfig, lastStudied: Date?) {
        try db.query(
            "SELECT \(Self.deckColumns) FROM decks WHERE id = ?", [.int(id)]
        ) { Self.config(from: $0) }.first ?? (StudyConfig(), VoiceConfig(), nil)
    }

    public func updateStudyConfig(_ config: StudyConfig, for id: Int64) throws {
        try db.run(
            """
            UPDATE decks SET new_per_day = ?, reviews_per_day = ?, desired_retention = ?,
                maximum_interval_days = ?, bury_new = ?, bury_reviews = ?, bury_interday = ?,
                fsrs_parameters = ?, easy_days = ?, learn_steps = ?, relearn_steps = ?,
                modified_at = ? WHERE id = ?
            """,
            [
                .int(Int64(config.newPerDay)), .int(Int64(config.reviewsPerDay)),
                .double(config.desiredRetention), .int(Int64(config.maximumIntervalDays)),
                .bool(config.buryNewSiblings), .bool(config.buryReviewSiblings),
                .bool(config.buryInterdayLearning),
                .optionalText(config.parameters.map { json($0) }),
                .text(json(config.easyDays)),
                .text(json(config.learningSteps)),
                .text(json(config.relearningSteps)),
                .date(Date()), .int(id),
            ]
        )
    }

    public struct FilteredSpec: Sendable, Equatable {
        public var query: String
        public var limit: Int
        public var order: Int
        public var reschedule: Bool

        public init(query: String, limit: Int, order: Int, reschedule: Bool) {
            self.query = query
            self.limit = limit
            self.order = order
            self.reschedule = reschedule
        }
    }

    public func filteredSpec(for id: Int64) throws -> FilteredSpec? {
        try db.query(
            "SELECT kind, filter_query, filter_limit, filter_order, reschedule FROM decks WHERE id = ?",
            [.int(id)]
        ) { row -> FilteredSpec? in
            guard row.int32(0) == DeckKind.filtered.rawValue else { return nil }
            return FilteredSpec(
                query: row.stringOrNil(1) ?? "",
                limit: row.int32(2),
                order: row.int32(3),
                reschedule: row.int(4) != 0
            )
        }.first ?? nil
    }

    public func setKind(_ kind: DeckKind, for id: Int64) throws {
        try db.run("UPDATE decks SET kind = ?, modified_at = ? WHERE id = ?", [.int(Int64(kind.rawValue)), .date(Date()), .int(id)])
    }

    public func setFilteredSpec(_ spec: FilteredSpec, for id: Int64) throws {
        try db.run(
            """
            UPDATE decks SET kind = ?, filter_query = ?, filter_limit = ?, filter_order = ?,
                reschedule = ?, modified_at = ? WHERE id = ?
            """,
            [
                .int(Int64(DeckKind.filtered.rawValue)), .text(spec.query),
                .int(Int64(spec.limit)), .int(Int64(spec.order)), .bool(spec.reschedule),
                .date(Date()), .int(id),
            ]
        )
    }

    public func updateVoiceConfig(_ config: VoiceConfig, for id: Int64) throws {
        try db.run(
            """
            UPDATE decks SET question_locale = ?, answer_locale = ?, question_voice = ?, answer_voice = ?,
                speech_rate = ?, use_default_speech_rate = ?, modified_at = ?
            WHERE id = ?
            """,
            [
                .text(config.questionLocale), .text(config.answerLocale),
                .optionalText(config.questionVoice), .optionalText(config.answerVoice),
                .double(config.speechRate), .bool(config.usesDefaultSpeechRate),
                .date(Date()), .int(id),
            ]
        )
    }

    public func markStudied(_ id: Int64, at date: Date = Date()) throws {
        try db.run("UPDATE decks SET last_studied_at = ? WHERE id = ?", [.date(date), .int(id)])
    }
}
