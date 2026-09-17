import Foundation

/// Pulls a deck (with its subdecks) straight out of a running Anki desktop
/// via AnkiConnect, preserving note types, tags, cards, review history,
/// suspension and the media files the cards reference.
///
/// Scheduling is rebuilt by replaying each card's review log through FSRS —
/// the same approach `ApkgImporter` uses when a package carries no FSRS
/// memory state. Notes are keyed by a stable `ankiconnect-<noteId>` guid so
/// re-importing the same deck later skips notes that already exist.
public struct AnkiConnectImporter: Sendable {

    public struct Progress: Sendable, Equatable {
        public enum Stage: Sendable, Equatable {
            case connecting
            case listingCards
            case fetchingCards(done: Int, total: Int)
            case fetchingNotes(done: Int, total: Int)
            case fetchingReviews(done: Int, total: Int)
            case writing(done: Int, total: Int)
            case media(done: Int, total: Int)
            case finished

            public var title: String {
                switch self {
                case .connecting: return "Connecting to Anki…"
                case .listingCards: return "Finding cards…"
                case .fetchingCards(let d, let t): return "Downloading cards \(d)/\(t)"
                case .fetchingNotes(let d, let t): return "Downloading notes \(d)/\(t)"
                case .fetchingReviews(let d, let t): return "Downloading review history \(d)/\(t)"
                case .writing(let d, let t): return "Saving notes \(d)/\(t)"
                case .media(let d, let t): return "Copying media \(d)/\(t)"
                case .finished: return "Done"
                }
            }

            /// 0…1 estimate for a progress bar.
            public var fraction: Double {
                func part(_ d: Int, _ t: Int) -> Double { t == 0 ? 1 : Double(d) / Double(t) }
                switch self {
                case .connecting: return 0.02
                case .listingCards: return 0.05
                case .fetchingCards(let d, let t): return 0.05 + 0.20 * part(d, t)
                case .fetchingNotes(let d, let t): return 0.25 + 0.15 * part(d, t)
                case .fetchingReviews(let d, let t): return 0.40 + 0.15 * part(d, t)
                case .writing(let d, let t): return 0.55 + 0.25 * part(d, t)
                case .media(let d, let t): return 0.80 + 0.20 * part(d, t)
                case .finished: return 1
                }
            }
        }
        public var stage: Stage
    }

    public struct Result: Sendable, Equatable {
        public var deckID: Int64
        public var deckName: String
        public var notesImported = 0
        public var notesSkipped = 0
        public var cardsImported = 0
        public var reviewsImported = 0
        public var mediaImported = 0
        public var mediaMissing = 0
        public var warnings: [String] = []
    }

    public enum ImportError: LocalizedError, Sendable {
        case emptyDeck(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .emptyDeck(let name): return "“\(name)” has no cards in Anki."
            case .cancelled: return "Import cancelled."
            }
        }
    }

    static let batchSize = 200
    static let guidPrefix = "ankiconnect-"

    private let client: AnkiConnectClient
    private let decks: DeckRepository
    private let cardsRepo: CardRepository
    private let reviewsRepo: ReviewRepository

    public init(client: AnkiConnectClient, decks: DeckRepository, cards: CardRepository, reviews: ReviewRepository) {
        self.client = client
        self.decks = decks
        self.cardsRepo = cards
        self.reviewsRepo = reviews
    }

    // MARK: - Import

    /// Imports `deckName` (an Anki full name such as `Japanese::JLPT N5`)
    /// including its subdecks.
    public func importDeck(
        named deckName: String,
        includeMedia: Bool = true,
        scheduler: FSRSScheduler = FSRSScheduler(),
        progress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> Result {
        var result = Result(deckID: 0, deckName: deckName)
        progress(Progress(stage: .connecting))
        _ = try await client.ping()

        // 1. Card ids for the deck (deck: search includes children).
        progress(Progress(stage: .listingCards))
        let escapedName = deckName.replacingOccurrences(of: "\"", with: "\\\"")
        let cardIDs = try await client.findCards(query: "deck:\"\(escapedName)\"")
        guard !cardIDs.isEmpty else { throw ImportError.emptyDeck(deckName) }
        try Task.checkCancellation()

        // 2. Card rows.
        var cards: [AnkiConnectClient.CardInfo] = []
        cards.reserveCapacity(cardIDs.count)
        for batch in cardIDs.chunked(into: Self.batchSize) {
            cards += try await client.cardsInfo(ids: batch)
            progress(Progress(stage: .fetchingCards(done: cards.count, total: cardIDs.count)))
            try Task.checkCancellation()
        }

        // 3. Notes.
        var noteIDs: [Int64] = []
        var seenNotes = Set<Int64>()
        for card in cards where !seenNotes.contains(card.note) {
            seenNotes.insert(card.note)
            noteIDs.append(card.note)
        }
        var notes: [AnkiConnectClient.NoteInfo] = []
        for batch in noteIDs.chunked(into: Self.batchSize) {
            notes += try await client.notesInfo(ids: batch)
            progress(Progress(stage: .fetchingNotes(done: notes.count, total: noteIDs.count)))
            try Task.checkCancellation()
        }

        // 4. Review history.
        var reviewsByCard: [Int64: [AnkiConnectClient.ReviewEntry]] = [:]
        var fetchedReviews = 0
        for batch in cardIDs.chunked(into: Self.batchSize) {
            let chunk = try await client.reviewsOfCards(ids: batch)
            reviewsByCard.merge(chunk) { _, new in new }
            fetchedReviews += batch.count
            progress(Progress(stage: .fetchingReviews(done: fetchedReviews, total: cardIDs.count)))
            try Task.checkCancellation()
        }

        // 5. Note types.
        let modelNames = Array(Set(cards.map(\.modelName))).sorted()
        let models = try await client.findModels(names: modelNames)
        var noteTypeIDByModelName: [String: Int64] = [:]
        for model in models {
            let fields = (model.flds ?? [])
                .sorted { ($0.ord ?? 0) < ($1.ord ?? 0) }
                .map(\.name)
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
                NoteType(
                    id: model.id, name: model.name,
                    fieldNames: fields.isEmpty ? ["Front", "Back"] : fields,
                    templates: templates.isEmpty ? NoteType.basic.templates : templates,
                    kind: kind
                )
            )
            noteTypeIDByModelName[model.name] = localID
        }
        for name in modelNames where noteTypeIDByModelName[name] == nil {
            result.warnings.append("Note type “\(name)” wasn't returned by Anki; its notes use the Basic type.")
        }

        // 6. Decks (hierarchy via :: names).
        let deckNames = Array(Set(cards.map(\.deckName) + [deckName])).sorted()
        var deckIDByName: [String: Int64] = [:]
        for name in deckNames {
            deckIDByName[name] = try decks.create(fullName: name).id
        }
        let rootDeckID = deckIDByName[deckName] ?? 0
        result.deckID = rootDeckID

        // 7. Notes + cards + review logs.
        var cardsByNote: [Int64: [AnkiConnectClient.CardInfo]] = [:]
        for card in cards { cardsByNote[card.note, default: []].append(card) }
        var mediaNames: [String] = []
        var seenMedia = Set<String>()

        for (index, note) in notes.enumerated() {
            try Task.checkCancellation()
            let guid = Self.guidPrefix + String(note.noteId)
            if try cardsRepo.note(guid: guid) != nil {
                result.notesSkipped += 1
                continue
            }
            let fields = note.orderedFieldValues
            guard !fields.isEmpty else { continue }
            let noteCards = (cardsByNote[note.noteId] ?? []).sorted { $0.ord < $1.ord }
            let noteTypeID = noteTypeIDByModelName[note.modelName] ?? 1
            let deckID = noteCards.first.flatMap { deckIDByName[$0.deckName] } ?? rootDeckID

            let created = try cardsRepo.createNote(
                fields: fields, tags: note.tags, deckID: deckID,
                noteTypeID: noteTypeID, guid: guid
            )
            result.notesImported += 1

            if includeMedia {
                for name in Self.mediaReferences(in: fields) where !seenMedia.contains(name) {
                    seenMedia.insert(name)
                    mediaNames.append(name)
                }
            }

            let localCards = try cardsRepo.cards(forNote: created.id)
            for ankiCard in noteCards {
                guard let local = localCards.first(where: { $0.templateOrdinal == ankiCard.ord }) ?? localCards.first
                else { continue }
                let history = Self.ratings(from: reviewsByCard[ankiCard.cardId] ?? [])
                let scheduling = Self.mapScheduling(card: ankiCard, history: history, scheduler: scheduler)
                try cardsRepo.replaceScheduling(scheduling, cardID: local.id)
                if ankiCard.queue == -1 {
                    try cardsRepo.setSuspended(true, cardID: local.id)
                }
                result.cardsImported += 1

                var previous = SchedulingState()
                for entry in history.prefix(2000) {
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

            if index % 25 == 0 || index == notes.count - 1 {
                progress(Progress(stage: .writing(done: index + 1, total: notes.count)))
            }
        }

        // 8. Media referenced by the imported notes.
        if includeMedia, !mediaNames.isEmpty {
            let mediaDir = try AppServices.mediaDirectory()
            for (index, name) in mediaNames.enumerated() {
                try Task.checkCancellation()
                let sanitized = name.replacingOccurrences(of: "/", with: "_")
                let destination = mediaDir.appendingPathComponent(sanitized)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    do {
                        if let bytes = try await client.retrieveMediaFile(named: name) {
                            try bytes.write(to: destination)
                            result.mediaImported += 1
                        } else {
                            result.mediaMissing += 1
                        }
                    } catch is CancellationError {
                        throw ImportError.cancelled
                    } catch {
                        result.mediaMissing += 1
                    }
                }
                if index % 5 == 0 || index == mediaNames.count - 1 {
                    progress(Progress(stage: .media(done: index + 1, total: mediaNames.count)))
                }
            }
            if result.mediaMissing > 0 {
                result.warnings.append("\(result.mediaMissing) media file(s) referenced by cards were not found in Anki.")
            }
        }

        progress(Progress(stage: .finished))
        return result
    }

    // MARK: - Helpers

    /// Filenames referenced by `[sound:…]` tags and `<img src=…>` elements.
    static func mediaReferences(in fields: [String]) -> [String] {
        var names: [String] = []
        let patterns = [#"\[sound:([^\]]+)\]"#, #"<img[^>]*src=["']?([^"'>\s]+)["']?[^>]*>"#]
        for field in fields {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(field.startIndex..., in: field)
                for match in regex.matches(in: field, range: range) where match.numberOfRanges > 1 {
                    guard let r = Range(match.range(at: 1), in: field) else { continue }
                    let raw = String(field[r]).removingPercentEncoding ?? String(field[r])
                    // Skip remote and data URLs — they aren't Anki media.
                    let lower = raw.lowercased()
                    if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") { continue }
                    names.append(raw)
                }
            }
        }
        return names
    }

    /// Converts revlog entries into FSRS-replayable ratings, dropping manual
    /// and rescheduled entries (types 4 and 5) that carry no button press.
    static func ratings(from entries: [AnkiConnectClient.ReviewEntry]) -> [(rating: Rating, at: Date, timeMs: Int)] {
        entries.compactMap { entry in
            guard entry.type != 4, entry.type != 5, let rating = Rating(rawValue: entry.ease) else { return nil }
            return (rating, Date(timeIntervalSince1970: Double(entry.id) / 1000.0), entry.time)
        }
    }

    /// Rebuilds our scheduling state for one Anki card.
    static func mapScheduling(
        card: AnkiConnectClient.CardInfo,
        history: [(rating: Rating, at: Date, timeMs: Int)],
        scheduler: FSRSScheduler
    ) -> SchedulingState {
        if !history.isEmpty {
            let replayed = scheduler.reschedule(ratings: history.map { (rating: $0.rating, at: $0.at) })
            var state = SchedulingState(memory: replayed)
            state.lapses = max(state.lapses, card.lapses)
            state.reps = max(state.reps, card.reps)
            return state
        }

        // No history: approximate from Anki's queue/interval. Review-card
        // `due` is relative to the collection creation day, which AnkiConnect
        // doesn't expose, so a card with an interval is treated as due now.
        // Suspended/buried cards (negative queue) fall back to the card type,
        // which uses the same 0 new / 1 learn / 2 review / 3 relearn numbering.
        var state = SchedulingState(lapses: card.lapses, reps: card.reps)
        let queue = card.queue < 0 ? card.type : card.queue
        switch queue {
        case 1:
            state.kind = .learning
            state.step = 0
            state.due = Date(timeIntervalSince1970: card.due)
        case 2 where card.interval != 0:
            state.kind = .review
            state.stability = Double(abs(card.interval))
            state.difficulty = 5.0
            state.due = Date()
            state.lastReview = Date(timeIntervalSince1970: card.mod)
        case 3:
            state.kind = .learning
            state.step = 0
            state.due = Date()
        default:
            state.kind = .new
            state.due = Date()
        }
        return state
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
