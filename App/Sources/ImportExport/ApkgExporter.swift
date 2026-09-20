import CryptoKit
import Foundation

/// Writes Anki deck/collection packages that desktop Anki, AnkiMobile and
/// AnkiDroid can import.
///
/// The package is the *legacy* format (`collection.anki2` inside a stored
/// ZIP, plus a JSON `media` map). That is what this app can also re-import;
/// modern zstd `.colpkg` files are intentionally not produced.
///
/// Scheduling (due dates, FSRS stability/difficulty, `revlog`) is included
/// unless `includeScheduling` is false, matching Anki's own export checkbox.
public struct ApkgExporter: Sendable {

    public struct Options: Sendable {
        public var includeScheduling: Bool
        public var includeMedia: Bool

        public init(includeScheduling: Bool = true, includeMedia: Bool = true) {
            self.includeScheduling = includeScheduling
            self.includeMedia = includeMedia
        }

        public static let `default` = Options()
        public static let cardsOnly = Options(includeScheduling: false, includeMedia: true)
    }

    public struct Result: Sendable, Equatable {
        public var url: URL
        public var notesExported = 0
        public var cardsExported = 0
        public var reviewsExported = 0
        public var mediaExported = 0
    }

    public enum ExportError: Error, LocalizedError, Equatable {
        case deckNotFound(Int64)
        case failedToWrite(String)

        public var errorDescription: String? {
            switch self {
            case .deckNotFound(let id):
                return "Couldn't find deck \(id) to export."
            case .failedToWrite(let path):
                return "Couldn't write the Anki package to \(path)."
            }
        }
    }

    private let decks: DeckRepository
    private let cards: CardRepository
    private let reviews: ReviewRepository

    public init(decks: DeckRepository, cards: CardRepository, reviews: ReviewRepository) {
        self.decks = decks
        self.cards = cards
        self.reviews = reviews
    }

    /// One deck and its children as an `.apkg` (Anki merges this on import).
    public func exportDeck(
        id: Int64,
        options: Options = .default,
        mediaDirectory: URL? = nil,
        to directory: URL? = nil
    ) throws -> Result {
        guard let root = try decks.deck(id: id) else { throw ExportError.deckNotFound(id) }
        let deckIDs = try cards.descendantDeckIDs(including: id)
        let exportedDecks = try deckIDs.compactMap { try decks.deck(id: $0) }
        let studyCards = try cards.studyCards(inDeckIDs: deckIDs)
        let logs = options.includeScheduling ? try reviews.history(inDeckIDs: deckIDs) : []
        let filename = Self.safeFilename(root.fullName) + ".apkg"
        return try writePackage(
            decks: exportedDecks,
            studyCards: studyCards,
            reviews: logs,
            currentDeckName: root.fullName,
            options: options,
            mediaDirectory: mediaDirectory,
            filename: filename,
            to: directory
        )
    }

    /// Whole collection as a `.colpkg` (Anki *replaces* the destination on import).
    public func exportCollection(
        options: Options = .default,
        mediaDirectory: URL? = nil,
        to directory: URL? = nil
    ) throws -> Result {
        let allDecks = try decks.all()
        let studyCards = try cards.allStudyCards()
        let logs = options.includeScheduling ? try reviews.allChronological() : []
        let filename = "AnkiVoice-Collection-\(ExportService.timestamp()).colpkg"
        return try writePackage(
            decks: allDecks,
            studyCards: studyCards,
            reviews: logs,
            currentDeckName: allDecks.first?.fullName,
            options: options,
            mediaDirectory: mediaDirectory,
            filename: filename,
            to: directory
        )
    }

    // MARK: - Package construction

    private func writePackage(
        decks exportedDecks: [Deck],
        studyCards: [StudyCard],
        reviews logs: [ReviewLog],
        currentDeckName: String?,
        options: Options,
        mediaDirectory: URL?,
        filename: String,
        to directory: URL?
    ) throws -> Result {
        var ids = UniqueIDs()

        var deckIDMap: [Int64: Int64] = [:]
        for deck in exportedDecks {
            deckIDMap[deck.id] = ids.ankiID(for: deck)
        }

        var modelIDMap: [Int64: Int64] = [:]
        var models: [Int64: NoteType] = [:]
        for item in studyCards {
            models[item.noteType.id] = item.noteType
        }
        if models.isEmpty {
            models[NoteType.basic.id] = NoteType.basic
        }
        for type in models.values.sorted(by: { $0.id < $1.id }) {
            modelIDMap[type.id] = ids.take(type.id >= 1_000_000_000_000 ? type.id : 1_600_000_000_000 + type.id)
        }

        var noteIDMap: [Int64: Int64] = [:]
        var cardIDMap: [Int64: Int64] = [:]
        // Notes first so two cards of the same note share one nid.
        var uniqueNotes: [Int64: StudyCard] = [:]
        for item in studyCards where uniqueNotes[item.note.id] == nil {
            uniqueNotes[item.note.id] = item
        }
        for item in uniqueNotes.values.sorted(by: { $0.note.id < $1.note.id }) {
            noteIDMap[item.note.id] = ids.from(item.note.createdAt, local: item.note.id)
        }
        for item in studyCards.sorted(by: { $0.card.id < $1.card.id }) {
            cardIDMap[item.card.id] = ids.from(item.card.createdAt, local: item.card.id &+ 1_000_000)
        }

        let crt = exportedDecks.map(\.createdAt.timeIntervalSince1970).min()
            ?? Date().timeIntervalSince1970
        let crtSeconds = Int64(crt)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anki-export-\(UUID().uuidString).sqlite")
        let packedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anki-packed-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: packedURL)
            try? FileManager.default.removeItem(atPath: tempURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: tempURL.path + "-shm")
        }

        try writeCollection(
            at: tempURL,
            packedTo: packedURL,
            crt: crtSeconds,
            decks: exportedDecks,
            deckIDMap: deckIDMap,
            models: Array(models.values),
            modelIDMap: modelIDMap,
            studyCards: studyCards,
            noteIDMap: noteIDMap,
            cardIDMap: cardIDMap,
            reviews: logs,
            currentDeckName: currentDeckName,
            options: options
        )

        var mediaCount = 0
        var writer = ZipWriter()
        writer.add(name: "collection.anki2", data: try Data(contentsOf: packedURL))

        var mediaMap: [String: String] = [:]
        if options.includeMedia, let mediaDirectory {
            let names = Self.referencedMedia(in: studyCards)
            for (index, name) in names.enumerated() {
                let source = mediaDirectory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let key = String(index)
                writer.add(name: key, data: try Data(contentsOf: source))
                mediaMap[key] = name
                mediaCount += 1
            }
        }
        writer.add(name: "media", data: try JSONSerialization.data(withJSONObject: mediaMap))

        let data = writer.finalize()
        let folder = directory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename)
        do {
            try data.write(to: url)
        } catch {
            throw ExportError.failedToWrite(url.path)
        }

        var result = Result(url: url)
        result.notesExported = uniqueNotes.count
        result.cardsExported = studyCards.count
        result.reviewsExported = options.includeScheduling ? logs.count : 0
        result.mediaExported = mediaCount
        return result
    }

    private func writeCollection(
        at url: URL,
        packedTo packedURL: URL,
        crt: Int64,
        decks exportedDecks: [Deck],
        deckIDMap: [Int64: Int64],
        models: [NoteType],
        modelIDMap: [Int64: Int64],
        studyCards: [StudyCard],
        noteIDMap: [Int64: Int64],
        cardIDMap: [Int64: Int64],
        reviews logs: [ReviewLog],
        currentDeckName: String?,
        options: Options
    ) throws {
        let db = try SQLiteDatabase.open(url: url)
        try db.execute(Self.ankiSchema)

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let nowSec = Int64(Date().timeIntervalSince1970)

        var dconf: [String: Any] = ["1": Self.defaultDConf(id: 1, name: "Default", study: StudyConfig())]
        var decksJSON: [String: Any] = [
            "1": Self.deckJSON(id: 1, name: "Default", conf: 1, mod: nowSec),
        ]
        var nextConfID: Int64 = 2
        for deck in exportedDecks {
            let ankiID = deckIDMap[deck.id] ?? 1
            let study = (try? decks.config(for: deck.id).study) ?? StudyConfig()
            let confID: Int64
            if ankiID == 1 {
                confID = 1
                dconf["1"] = Self.defaultDConf(id: 1, name: "Default", study: study)
            } else {
                confID = nextConfID
                dconf[String(confID)] = Self.defaultDConf(id: confID, name: deck.name, study: study)
                nextConfID += 1
            }
            decksJSON[String(ankiID)] = Self.deckJSON(id: ankiID, name: deck.fullName, conf: confID, mod: nowSec)
        }

        var modelsJSON: [String: Any] = [:]
        for type in models {
            guard let mid = modelIDMap[type.id] else { continue }
            modelsJSON[String(mid)] = Self.modelJSON(type, id: mid, mod: nowSec)
        }

        let currentDeckID: Int64 = {
            if let name = currentDeckName,
               let deck = exportedDecks.first(where: { $0.fullName == name }),
               let mapped = deckIDMap[deck.id] {
                return mapped
            }
            return deckIDMap.values.sorted().first ?? 1
        }()

        let nextPos = max(1, studyCards.filter { $0.card.scheduling.kind == .new }.count + 1)
        let conf: [String: Any] = [
            "nextPos": nextPos,
            "estTimes": true,
            "activeDecks": [Int(currentDeckID)],
            "sortType": "noteFld",
            "timeLim": 0,
            "sortBackwards": false,
            "addToCur": true,
            "curDeck": Int(currentDeckID),
            "newSpread": 0,
            "dueCounts": true,
            "collapseTime": 1200,
        ]

        try db.run(
            """
            INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
            VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')
            """,
            [
                .int(crt), .int(nowMs), .int(nowMs),
                .text(Self.jsonObject(conf)),
                .text(Self.jsonObject(modelsJSON)),
                .text(Self.jsonObject(decksJSON)),
                .text(Self.jsonObject(dconf)),
            ]
        )

        let noteInsert = """
            INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
            VALUES (?,?,?,?,0,?,?,?,?,0,'')
            """
        var writtenNotes = Set<Int64>()
        for item in studyCards {
            guard writtenNotes.insert(item.note.id).inserted else { continue }
            guard let nid = noteIDMap[item.note.id], let mid = modelIDMap[item.note.noteTypeID] else { continue }
            let fieldNames = item.noteType.fieldNames
            var fields = item.note.fields
            if fields.count < fieldNames.count {
                fields.append(contentsOf: Array(repeating: "", count: fieldNames.count - fields.count))
            }
            let flds = fields.joined(separator: "\u{1f}")
            let sfld = fields.first ?? ""
            let tags = Self.ankiTags(item.note.tags, includeScheduling: options.includeScheduling)
            try db.run(
                noteInsert,
                [
                    .int(nid), .text(item.note.guid), .int(mid),
                    .int(Int64(item.note.modifiedAt.timeIntervalSince1970)),
                    .text(tags), .text(flds), .text(sfld),
                    .int(Self.fieldChecksum(sfld)),
                ]
            )
        }

        let cardInsert = """
            INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor,
                               reps, lapses, left, odue, odid, flags, data)
            VALUES (?,?,?,?,?,0,?,?,?,?,?,?,?,0,0,0,0,?)
            """
        var newOrder = 1
        for item in studyCards {
            guard let cid = cardIDMap[item.card.id], let nid = noteIDMap[item.note.id] else { continue }
            let did = deckIDMap[item.card.deckID] ?? 1
            let mapped = Self.mapCard(
                item.card, crt: crt, newOrder: &newOrder, includeScheduling: options.includeScheduling
            )
            try db.run(
                cardInsert,
                [
                    .int(cid), .int(nid), .int(did), .int(Int64(item.card.templateOrdinal)),
                    .int(Int64(item.card.modifiedAt.timeIntervalSince1970)),
                    .int(Int64(mapped.type)), .int(Int64(mapped.queue)), .int(mapped.due),
                    .int(Int64(mapped.ivl)), .int(Int64(mapped.factor)),
                    .int(Int64(mapped.reps)), .int(Int64(mapped.lapses)),
                    .text(mapped.data),
                ]
            )
        }

        if options.includeScheduling {
            var usedRevlog = Set<Int64>()
            let revlogInsert = """
                INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
                VALUES (?,?,0,?,?,?,?,?,?)
                """
            for log in logs {
                guard let cid = cardIDMap[log.cardID] else { continue }
                var rid = Int64(log.reviewedAt.timeIntervalSince1970 * 1000)
                if rid <= 0 { rid = 1 }
                while usedRevlog.contains(rid) { rid += 1 }
                usedRevlog.insert(rid)
                let mapped = Self.mapRevlog(log)
                try db.run(
                    revlogInsert,
                    [
                        .int(rid), .int(cid),
                        .int(Int64(log.rating.rawValue)),
                        .int(Int64(mapped.ivl)), .int(Int64(mapped.lastIvl)),
                        .int(Int64(mapped.factor)),
                        .int(Int64(min(max(0, log.durationMs), 60_000))),
                        .int(Int64(mapped.type)),
                    ]
                )
            }
        }

        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let escaped = packedURL.path.replacingOccurrences(of: "'", with: "''")
        try db.execute("VACUUM INTO '\(escaped)'")
    }

    // MARK: - Mapping

    private struct MappedCard {
        var type: Int
        var queue: Int
        var due: Int64
        var ivl: Int
        var factor: Int
        var reps: Int
        var lapses: Int
        var data: String
    }

    private static func mapCard(
        _ card: Card, crt: Int64, newOrder: inout Int, includeScheduling: Bool
    ) -> MappedCard {
        if !includeScheduling {
            let due = newOrder
            newOrder += 1
            return MappedCard(type: 0, queue: 0, due: Int64(due), ivl: 0, factor: 2500, reps: 0, lapses: 0, data: "")
        }

        let s = card.scheduling
        var type: Int
        var queue: Int
        var due: Int64
        var ivl = 0
        switch s.kind {
        case .new:
            type = 0
            queue = 0
            due = Int64(newOrder)
            newOrder += 1
        case .learning:
            type = 1
            queue = 1
            due = Int64(s.due.timeIntervalSince1970)
        case .relearning:
            type = 3
            queue = 1
            due = Int64(s.due.timeIntervalSince1970)
        case .review:
            type = 2
            queue = 2
            let days = (s.due.timeIntervalSince1970 - Double(crt)) / 86_400
            due = Int64(days.rounded(.towardZero))
            ivl = max(1, Int((s.stability ?? max(days, 1)).rounded()))
        }
        if card.suspended { queue = -1 }

        var data = ""
            if let stability = s.stability, let difficulty = s.difficulty, s.kind != .new {
            data = Self.jsonObject(["s": stability, "d": difficulty] as [String: Double])
        }
        let factor: Int
        if let difficulty = s.difficulty {
            factor = max(0, Int((difficulty * 1000).rounded()))
        } else {
            factor = 2500
        }
        return MappedCard(
            type: type, queue: queue, due: due, ivl: ivl, factor: factor,
            reps: s.reps, lapses: s.lapses, data: data
        )
    }

    private struct MappedRevlog {
        var ivl: Int
        var lastIvl: Int
        var factor: Int
        var type: Int
    }

    private static func mapRevlog(_ log: ReviewLog) -> MappedRevlog {
        func interval(_ state: SchedulingState) -> Int {
            switch state.kind {
            case .new:
                return 0
            case .learning, .relearning:
                return -600
            case .review:
                if let stability = state.stability { return max(1, Int(stability.rounded())) }
                return 1
            }
        }
        let type: Int
        switch log.previousState.kind {
        case .new, .learning: type = 0
        case .review: type = 1
        case .relearning: type = 2
        }
        let factor: Int
        if let difficulty = log.newState.difficulty {
            factor = max(0, Int((difficulty * 1000).rounded()))
        } else {
            factor = 0
        }
        return MappedRevlog(
            ivl: interval(log.newState),
            lastIvl: interval(log.previousState),
            factor: factor,
            type: type
        )
    }

    // MARK: - JSON payloads

    private static func modelJSON(_ type: NoteType, id: Int64, mod: Int64) -> [String: Any] {
        let fields: [[String: Any]] = type.fieldNames.enumerated().map { index, name in
            [
                "name": name, "ord": index, "sticky": false, "rtl": false,
                "font": "Arial", "size": 20, "description": "",
            ]
        }
        let templates: [[String: Any]] = type.templates.enumerated().map { index, tmpl in
            [
                "name": tmpl.name.isEmpty ? "Card \(index + 1)" : tmpl.name,
                "ord": tmpl.ordinal,
                "qfmt": tmpl.questionFormat,
                "afmt": tmpl.answerFormat,
                "bqfmt": "", "bafmt": "", "bfont": "", "bsize": 0,
            ]
        }
        return [
            "id": Int(id),
            "name": type.name,
            "type": type.kind.rawValue,
            "mod": Int(mod),
            "usn": 0,
            "sortf": 0,
            "css": Self.defaultCSS,
            "latexPre": Self.latexPre,
            "latexPost": Self.latexPost,
            "latexsvg": false,
            "flds": fields,
            "tmpls": templates.isEmpty ? [[
                "name": "Card 1", "ord": 0,
                "qfmt": "{{Front}}",
                "afmt": "{{FrontSide}}\n<hr id=answer>\n{{Back}}",
                "bqfmt": "", "bafmt": "", "bfont": "", "bsize": 0,
            ]] : templates,
        ]
    }

    private static func deckJSON(id: Int64, name: String, conf: Int64, mod: Int64) -> [String: Any] {
        [
            "id": Int(id),
            "name": name,
            "mod": Int(mod),
            "usn": 0,
            "collapsed": false,
            "browserCollapsed": false,
            "desc": "",
            "dyn": 0,
            "conf": Int(conf),
            "extendNew": 0,
            "extendRev": 0,
            "newToday": [0, 0],
            "revToday": [0, 0],
            "lrnToday": [0, 0],
            "timeToday": [0, 0],
        ]
    }

    private static func defaultDConf(id: Int64, name: String, study: StudyConfig) -> [String: Any] {
        [
            "id": Int(id),
            "mod": 0,
            "name": name,
            "usn": 0,
            "maxTaken": 60,
            "autoplay": true,
            "timer": 0,
            "replayq": true,
            "dyn": false,
            "fsrs": true,
            "desiredRetention": study.desiredRetention,
            "new": [
                "bury": true,
                "delays": [1.0, 10.0],
                "initialFactor": 2500,
                "ints": [1, 4, 0],
                "order": 1,
                "perDay": study.newPerDay,
            ] as [String: Any],
            "rev": [
                "bury": true,
                "ease4": 1.3,
                "ivlFct": 1.0,
                "maxIvl": study.maximumIntervalDays,
                "perDay": study.reviewsPerDay,
                "hardFactor": 1.2,
            ] as [String: Any],
            "lapse": [
                "delays": [10.0],
                "leechAction": 1,
                "leechFails": 8,
                "minInt": 1,
                "mult": 0.0,
            ] as [String: Any],
        ]
    }

    private static let defaultCSS = """
        .card { font-family: arial; font-size: 20px; text-align: center; color: black; background-color: white; }
        """
    private static let latexPre = """
        \\documentclass[12pt]{article}
        \\special{papersize=3in,5in}
        \\usepackage[utf8]{inputenc}
        \\usepackage{amssymb,amsmath}
        \\pagestyle{empty}
        \\setlength{\\parindent}{0in}
        \\begin{document}
        """
    private static let latexPost = "\\end{document}"

    private static let ankiSchema = """
        CREATE TABLE col (
            id integer primary key, crt integer not null, mod integer not null,
            scm integer not null, ver integer not null, dty integer not null,
            usn integer not null, ls integer not null, conf text not null,
            models text not null, decks text not null, dconf text not null,
            tags text not null
        );
        CREATE TABLE notes (
            id integer primary key, guid text not null, mid integer not null,
            mod integer not null, usn integer not null, tags text not null,
            flds text not null, sfld text not null, csum integer not null,
            flags integer not null, data text not null
        );
        CREATE TABLE cards (
            id integer primary key, nid integer not null, did integer not null,
            ord integer not null, mod integer not null, usn integer not null,
            type integer not null, queue integer not null, due integer not null,
            ivl integer not null, factor integer not null, reps integer not null,
            lapses integer not null, left integer not null, odue integer not null,
            odid integer not null, flags integer not null, data text not null
        );
        CREATE TABLE revlog (
            id integer primary key, cid integer not null, usn integer not null,
            ease integer not null, ivl integer not null, lastIvl integer not null,
            factor integer not null, time integer not null, type integer not null
        );
        CREATE TABLE graves (
            usn integer not null, oid integer not null, type integer not null
        );
        CREATE INDEX ix_notes_usn on notes (usn);
        CREATE INDEX ix_cards_usn on cards (usn);
        CREATE INDEX ix_revlog_usn on revlog (usn);
        CREATE INDEX ix_cards_nid on cards (nid);
        CREATE INDEX ix_cards_sched on cards (did, queue, due);
        CREATE INDEX ix_revlog_cid on revlog (cid);
        CREATE INDEX ix_notes_csum on notes (csum);
        """

    // MARK: - Helpers

    private struct UniqueIDs {
        private var used: Set<Int64> = []

        mutating func take(_ preferred: Int64) -> Int64 {
            var id = preferred <= 0 ? 1 : preferred
            while used.contains(id) { id += 1 }
            used.insert(id)
            return id
        }

        mutating func from(_ date: Date, local: Int64) -> Int64 {
            let ms = Int64(date.timeIntervalSince1970 * 1000)
            return take(ms &+ (local % 1_000))
        }

        mutating func ankiID(for deck: Deck) -> Int64 {
            if deck.fullName == "Default" { return take(1) }
            // Anki reserves id 1 for Default; never emit it for another deck.
            let preferred = max(2, Int64(deck.createdAt.timeIntervalSince1970 * 1000))
            return take(preferred)
        }
    }

    static func safeFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: Deck.nameSeparator, with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Deck" : String(cleaned.prefix(80))
    }

    private static func ankiTags(_ tags: [String], includeScheduling: Bool) -> String {
        var tags = tags.filter { !$0.isEmpty }
        if !includeScheduling {
            tags.removeAll { $0.caseInsensitiveCompare("marked") == .orderedSame
                || $0.caseInsensitiveCompare("leech") == .orderedSame }
        }
        guard !tags.isEmpty else { return "" }
        return " " + tags.joined(separator: " ") + " "
    }

    /// Anki's `fieldChecksum`: first 8 hex digits of SHA-1 of the stripped sort field.
    static func fieldChecksum(_ text: String) -> Int64 {
        let stripped = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let digest = Insecure.SHA1.hash(data: Data(stripped.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Int64(hex.prefix(8), radix: 16) ?? 0
    }

    static func referencedMedia(in cards: [StudyCard]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for card in cards {
            for name in mediaFilenames(in: card.note.fields) where seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    static func mediaFilenames(in fields: [String]) -> [String] {
        let text = fields.joined(separator: "\n")
        var names: [String] = []
        func addMatches(_ pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[r])
                if name.isEmpty || name.contains("://") { continue }
                names.append((name as NSString).lastPathComponent)
            }
        }
        addMatches(#"\[sound:([^\]]+)\]"#)
        addMatches(#"(?:src|data)=["']([^"']+)["']"#)
        return names
    }

    private static func jsonObject(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
