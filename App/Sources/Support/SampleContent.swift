import Foundation

/// Seeds first-run content: a sample deck used by the onboarding voice
/// tutorial (PRD §36) and the MVP-0 prototype cards.
public enum SampleContent {

    /// The canonical three-card tutorial deck (PRD §36, screen 5).
    public static let tutorialDeckName = "Tutorial"

    public static let tutorialCards: [(front: String, back: String)] = [
        ("What is the capital of France?", "Paris"),
        ("What does 'ubiquitous' mean?", "Present, appearing, or found everywhere."),
        ("The powerhouse of the cell is the…", "Mitochondrion."),
    ]

    /// A starter deck demonstrating hands-free study (PRD §52: ~20 cards).
    public static let starterDeckName = "Starter::General Knowledge"

    public static let starterCards: [(front: String, back: String)] = [
        ("What is the capital of France?", "Paris"),
        ("What is the capital of Japan?", "Tokyo"),
        ("What does DNA stand for?", "Deoxyribonucleic acid"),
        ("How many continents are there?", "Seven"),
        ("What is the largest ocean?", "The Pacific Ocean"),
        ("What year did the Berlin Wall fall?", "1989"),
        ("What is the chemical symbol for gold?", "Au"),
        ("What planet is known as the Red Planet?", "Mars"),
        ("Who wrote 'Pride and Prejudice'?", "Jane Austen"),
        ("What is the speed of light, roughly?", "About 300,000 kilometers per second"),
        ("What gas do plants absorb from the air?", "Carbon dioxide"),
        ("How many bones are in the adult human body?", "206"),
        ("What is the longest river in the world?", "The Nile"),
        ("What does 'ephemeral' mean?", "Lasting for a very short time"),
        ("What is the boiling point of water at sea level?", "100 degrees Celsius"),
        ("Who painted the Mona Lisa?", "Leonardo da Vinci"),
        ("What is the largest mammal?", "The blue whale"),
        ("What does 'benevolent' mean?", "Kind and well-meaning"),
        ("Which vitamin is produced when skin is exposed to sunlight?", "Vitamin D"),
        ("What is the square root of 144?", "12"),
    ]

    /// Creates the sample decks on first launch. Runs once per install so a
    /// user who deletes them isn't handed them back on the next visit.
    @MainActor
    public static func seedIfNeeded(decks: DeckRepository, cards: CardRepository, settings: SettingsStore) throws {
        guard !settings.sampleContentSeeded else { return }
        _ = try ensureTutorialDeck(decks: decks, cards: cards)
        if try decks.deck(named: starterDeckName) == nil {
            try seed(starterCards, into: starterDeckName, decks: decks, cards: cards)
        }
        settings.sampleContentSeeded = true
    }

    /// The tutorial deck, created if the user deleted it before re-running onboarding.
    public static func ensureTutorialDeck(decks: DeckRepository, cards: CardRepository) throws -> Deck {
        if let existing = try decks.deck(named: tutorialDeckName) { return existing }
        return try seed(tutorialCards, into: tutorialDeckName, decks: decks, cards: cards)
    }

    @discardableResult
    private static func seed(
        _ content: [(front: String, back: String)], into deckName: String,
        decks: DeckRepository, cards: CardRepository
    ) throws -> Deck {
        let deck = try decks.create(fullName: deckName)
        for card in content {
            _ = try cards.createNote(fields: [card.front, card.back], deckID: deck.id)
        }
        return deck
    }
}
