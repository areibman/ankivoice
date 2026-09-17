import Foundation

/// CRUD and queries for decks, including study/voice configuration.
public final class DeckRepository: @unchecked Sendable {
    let db: SQLiteDatabase

    public init(db: SQLiteDatabase) { self.db = db }

    // MARK: Mapping

    struct DeckRow {
        var id: Int64
        var name: String
        var fullName: String
        var parentID: Int64?
        var createdAt: Date
        var modifiedAt: Date
        var study: StudyConfig
        var voice: VoiceConfig
        var lastStudiedAt: Date?
    }

    static func rowToDeck(_ r: Row) -> Deck {
        Deck(
            id: r.int(0),
            name: r.string(1),
            fullName: r.string(2),
            parentID: r.isNull(3) ? nil : r.int(3),
            createdAt: r.date(4),
            modifiedAt: r.date(5)
        )
    }

    static let deckColumns = """
        id, name, full_name, parent_id, created_at, modified_at,
        new_per_day, reviews_per_day, desired_retention, maximum_interval_days,
        question_locale, answer_locale, question_voice, answer_voice,
        speech_rate, endpoint_delay_ms, semantic_grading_enabled, last_studied_at,
        use_default_speech_rate
        """

    static func config(from r: Row) -> (study: StudyConfig, voice: VoiceConfig, lastStudied: Date?) {
        let study = StudyConfig(
            newPerDay: r.int32(6),
            reviewsPerDay: r.int32(7),
            desiredRetention: r.double(8),
            maximumIntervalDays: r.int32(9)
        )
        let voice = VoiceConfig(
            questionLocale: r.string(10),
            answerLocale: r.string(11),
            questionVoice: r.stringOrNil(12),
            answerVoice: r.stringOrNil(13),
            speechRate: r.double(14),
            usesDefaultSpeechRate: r.int(18) != 0,
            endpointDelayMs: r.int32(15),
            semanticGradingEnabled: r.int(16) != 0
        )
        return (study, voice, r.dateOrNil(17))
    }

    // MARK: CRUD

    /// Creates a deck (and any missing ancestors implied by a `::`-separated full name).
    @discardableResult
    public func create(fullName: String, defaultConfig: Bool = true) throws -> Deck {
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
                maximum_interval_days = ?, modified_at = ? WHERE id = ?
            """,
            [
                .int(Int64(config.newPerDay)), .int(Int64(config.reviewsPerDay)),
                .double(config.desiredRetention), .int(Int64(config.maximumIntervalDays)),
                .date(Date()), .int(id),
            ]
        )
    }

    public func updateVoiceConfig(_ config: VoiceConfig, for id: Int64) throws {
        try db.run(
            """
            UPDATE decks SET question_locale = ?, answer_locale = ?, question_voice = ?, answer_voice = ?,
                speech_rate = ?, endpoint_delay_ms = ?, semantic_grading_enabled = ?,
                use_default_speech_rate = ?, modified_at = ?
            WHERE id = ?
            """,
            [
                .text(config.questionLocale), .text(config.answerLocale),
                .optionalText(config.questionVoice), .optionalText(config.answerVoice),
                .double(config.speechRate), .int(Int64(config.endpointDelayMs)),
                .bool(config.semanticGradingEnabled), .bool(config.usesDefaultSpeechRate),
                .date(Date()), .int(id),
            ]
        )
    }

    public func markStudied(_ id: Int64, at date: Date = Date()) throws {
        try db.run("UPDATE decks SET last_studied_at = ? WHERE id = ?", [.date(date), .int(id)])
    }
}
