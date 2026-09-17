import Foundation

/// Database schema creation and migration.
public enum Schema {
    public static let version = 2

    public static func migrate(db: SQLiteDatabase) throws {
        try db.transaction {
            let versionRows = (try? db.query("PRAGMA user_version", [], { $0.int32(0) })) ?? []
            let current = versionRows.first ?? 0
            guard current < version else { return }

            if current < 1 {
                try createV1(db: db)
            }
            if current < 2 {
                try migrateV2(db: db)
            }

            try db.run("PRAGMA user_version = \(version)")
        }
    }

    /// v2: decks follow the global speaking speed unless they opt out.
    private static func migrateV2(db: SQLiteDatabase) throws {
        let columns = try db.query("PRAGMA table_info(decks)") { $0.string(1) }
        if !columns.contains("use_default_speech_rate") {
            try db.execute("ALTER TABLE decks ADD COLUMN use_default_speech_rate INTEGER NOT NULL DEFAULT 1;")
        }
    }

    private static func createV1(db: SQLiteDatabase) throws {
        try db.execute("""
        CREATE TABLE decks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            full_name TEXT NOT NULL UNIQUE,
            parent_id INTEGER REFERENCES decks(id) ON DELETE SET NULL,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL,
            -- study configuration
            new_per_day INTEGER NOT NULL DEFAULT 20,
            reviews_per_day INTEGER NOT NULL DEFAULT 200,
            desired_retention REAL NOT NULL DEFAULT 0.9,
            maximum_interval_days INTEGER NOT NULL DEFAULT 36500,
            -- voice configuration
            question_locale TEXT NOT NULL DEFAULT 'en-US',
            answer_locale TEXT NOT NULL DEFAULT 'en-US',
            question_voice TEXT,
            answer_voice TEXT,
            speech_rate REAL NOT NULL DEFAULT 1.0,
            endpoint_delay_ms INTEGER NOT NULL DEFAULT 700,
            semantic_grading_enabled INTEGER NOT NULL DEFAULT 0,
            last_studied_at REAL
        );
        """)

        try db.execute("""
        CREATE TABLE note_types (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            field_names TEXT NOT NULL,
            templates TEXT NOT NULL,
            kind INTEGER NOT NULL DEFAULT 0
        );
        """)

        try db.execute("""
        CREATE TABLE notes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            note_type_id INTEGER NOT NULL REFERENCES note_types(id),
            fields TEXT NOT NULL,
            tags TEXT NOT NULL DEFAULT '',
            guid TEXT NOT NULL,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL,
            UNIQUE(guid)
        );
        CREATE INDEX idx_notes_guid ON notes(guid);
        """)

        try db.execute("""
        CREATE TABLE cards (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
            template_ordinal INTEGER NOT NULL DEFAULT 0,
            state INTEGER NOT NULL DEFAULT 0,
            step INTEGER,
            due REAL NOT NULL,
            stability REAL,
            difficulty REAL,
            last_review REAL,
            lapses INTEGER NOT NULL DEFAULT 0,
            reps INTEGER NOT NULL DEFAULT 0,
            suspended INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            modified_at REAL NOT NULL
        );
        CREATE INDEX idx_cards_deck_due ON cards(deck_id, due);
        CREATE INDEX idx_cards_note ON cards(note_id);
        CREATE INDEX idx_cards_state_due ON cards(state, due);
        """)

        try db.execute("""
        CREATE TABLE reviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
            rating INTEGER NOT NULL,
            reviewed_at REAL NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            study_mode INTEGER NOT NULL DEFAULT 1,
            previous_state TEXT NOT NULL,
            new_state TEXT NOT NULL
        );
        CREATE INDEX idx_reviews_card ON reviews(card_id, reviewed_at);
        CREATE INDEX idx_reviews_time ON reviews(reviewed_at);
        """)

        try db.execute("""
        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

        // Built-in note types.
        for (id, nt) in [(Int64(1), NoteType.basic), (Int64(2), NoteType.basicReversed)] {
            try db.run(
                "INSERT INTO note_types (id, name, field_names, templates, kind) VALUES (?,?,?,?,?)",
                [.int(id), .text(nt.name), .text(json(nt.fieldNames)), .text(json(nt.templates)), .int(Int64(nt.kind.rawValue))]
            )
        }
    }
}

func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
    try? JSONDecoder().decode(type, from: Data(text.utf8))
}
