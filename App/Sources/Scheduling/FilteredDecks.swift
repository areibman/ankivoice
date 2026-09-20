import Foundation

/// Builds and rebuilds a filtered deck the way Anki's custom study does:
/// gather matching cards, remember their home deck, and hand them back
/// after they are answered (or when the deck is rebuilt or deleted).
public struct FilteredDeckBuilder: Sendable {
    public enum Order: Int, Sendable, CaseIterable {
        case due = 0
        case random = 1
        case added = 2
        case intervals = 3
        case retrievability = 4

        public var title: String {
            switch self {
            case .due: return "Due date"
            case .random: return "Random"
            case .added: return "Date added"
            case .intervals: return "Intervals"
            case .retrievability: return "Retrievability"
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

    /// Creates or replaces `name` and moves up to `limit` matching cards into it.
    @discardableResult
    public func rebuild(
        named name: String, query: String, limit: Int, order: Order, reschedule: Bool,
        now: Date = Date()
    ) throws -> Deck {
        let deck = try decks.create(fullName: name)
        try returnHome(deckID: deck.id)
        try decks.setFilteredSpec(
            DeckRepository.FilteredSpec(query: query, limit: limit, order: order.rawValue, reschedule: reschedule),
            for: deck.id
        )

        let filteredIDs = Set(try cards.db.query(
            "SELECT id FROM decks WHERE kind = ?", [.int(Int64(DeckKind.filtered.rawValue))]
        ) { $0.int(0) })
        let pool = try cards.allStudyCards().filter { card in
            card.card.originalDeckID == nil && !filteredIDs.contains(card.card.deckID) && !card.card.suspended
        }
        let reviewed = try reviewIndex()
        let scheduler = FSRSScheduler()
        var matched = BrowserQuery.match(pool, query: query, now: now, reviewed: reviewed) { card in
            scheduler.retrievability(of: card.card.scheduling.memoryState, now: now)
        }
        matched = sort(matched, order: order, now: now)
        if limit > 0 { matched = Array(matched.prefix(limit)) }
        for (index, card) in matched.enumerated() {
            try cards.placeInFiltered(card.id, deckID: deck.id, position: index)
        }
        return try decks.deck(id: deck.id) ?? deck
    }

    public func returnHome(deckID: Int64) throws {
        let ids = try cards.db.query(
            "SELECT id FROM cards WHERE deck_id = ? AND original_deck_id IS NOT NULL",
            [.int(deckID)]
        ) { $0.int(0) }
        for id in ids {
            try cards.returnFromFiltered(id)
        }
    }

    private func reviewIndex() throws -> [Int64: [ReviewLog]] {
        Dictionary(grouping: try reviews.allChronological(), by: \.cardID)
    }

    private func sort(_ cards: [StudyCard], order: Order, now: Date) -> [StudyCard] {
        switch order {
        case .due:
            return cards.sorted { $0.card.scheduling.due < $1.card.scheduling.due }
        case .random:
            return cards.shuffled()
        case .added:
            return cards.sorted { $0.note.createdAt > $1.note.createdAt }
        case .intervals:
            return cards.sorted {
                ($0.card.scheduling.stability ?? 0) < ($1.card.scheduling.stability ?? 0)
            }
        case .retrievability:
            let scheduler = FSRSScheduler()
            return cards.sorted {
                scheduler.retrievability(of: $0.card.scheduling.memoryState, now: now)
                    < scheduler.retrievability(of: $1.card.scheduling.memoryState, now: now)
            }
        }
    }
}
