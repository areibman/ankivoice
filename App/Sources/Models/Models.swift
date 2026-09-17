import Foundation

// MARK: - Rating

/// The four canonical FSRS ratings.
/// `again` is failure to recall; `hard` is successful but difficult recall.
public enum Rating: Int, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }

    /// Short spoken description used during onboarding/teaching.
    public var spokenDescription: String {
        switch self {
        case .again: return "Didn't remember"
        case .hard: return "Remembered with difficulty"
        case .good: return "Remembered"
        case .easy: return "Immediate recall"
        }
    }

    /// One or two words for the rating buttons, short enough that all four
    /// fit in equal-width columns.
    public var shortDescription: String {
        switch self {
        case .again: return "Forgot"
        case .hard: return "Struggled"
        case .good: return "Got it"
        case .easy: return "Instant"
        }
    }
}

// MARK: - Scheduling state

/// Scheduling state of a card, kept independent of card content.
public enum CardStateKind: Int, Codable, Sendable, Hashable {
    case new = 0
    case learning = 1
    case review = 2
    case relearning = 3
}

/// Complete scheduling metadata for one card (PRD §23: stored independently from content).
public struct SchedulingState: Codable, Sendable, Hashable {
    public var kind: CardStateKind
    /// Current learning/relearning step index (nil outside learning states).
    public var step: Int?
    /// FSRS stability in days (nil until first review).
    public var stability: Double?
    /// FSRS difficulty in [1, 10] (nil until first review).
    public var difficulty: Double?
    /// Next due instant.
    public var due: Date
    /// Last review instant (nil until first review).
    public var lastReview: Date?
    public var lapses: Int
    public var reps: Int

    public init(
        kind: CardStateKind = .new,
        step: Int? = nil,
        stability: Double? = nil,
        difficulty: Double? = nil,
        due: Date = Date(),
        lastReview: Date? = nil,
        lapses: Int = 0,
        reps: Int = 0
    ) {
        self.kind = kind
        self.step = step
        self.stability = stability
        self.difficulty = difficulty
        self.due = due
        self.lastReview = lastReview
        self.lapses = lapses
        self.reps = reps
    }

    public var isNew: Bool { kind == .new }
}

// MARK: - Deck

public struct Deck: Identifiable, Codable, Sendable, Hashable {
    public var id: Int64
    public var name: String
    /// Anki-style hierarchical name, e.g. "Languages::Japanese::Vocabulary".
    public var fullName: String
    public var parentID: Int64?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: Int64, name: String, fullName: String, parentID: Int64?,
        createdAt: Date = Date(), modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.parentID = parentID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public static let nameSeparator = "::"
}

/// Per-deck study limits.
public struct StudyConfig: Codable, Sendable, Hashable {
    public var newPerDay: Int
    public var reviewsPerDay: Int
    /// Requested retention for FSRS interval computation, in (0, 1).
    public var desiredRetention: Double
    /// Maximum review interval in days.
    public var maximumIntervalDays: Int

    public init(
        newPerDay: Int = 20,
        reviewsPerDay: Int = 200,
        desiredRetention: Double = 0.9,
        maximumIntervalDays: Int = 36_500
    ) {
        self.newPerDay = newPerDay
        self.reviewsPerDay = reviewsPerDay
        self.desiredRetention = desiredRetention
        self.maximumIntervalDays = maximumIntervalDays
    }
}

/// Which side of a card is being spoken. Lets the synthesizer pick the
/// question or answer voice even when both sides share a locale.
public enum SpeechSide: Codable, Sendable, Hashable {
    case question
    case answer
}

/// Per-deck voice behavior (PRD §47 DeckVoiceSettings).
public struct VoiceConfig: Codable, Sendable, Hashable {
    /// BCP-47 tag for the card front, e.g. "ja-JP".
    public var questionLocale: String
    /// BCP-47 tag for the card back.
    public var answerLocale: String
    /// Explicit voice identifiers; nil = the user's default voice for the locale.
    public var questionVoice: String?
    public var answerVoice: String?
    /// Speech rate multiplier around AVSpeechUtteranceDefaultSpeechRate.
    public var speechRate: Double
    /// When true the deck follows the global speaking-speed setting and
    /// `speechRate` is ignored.
    public var usesDefaultSpeechRate: Bool
    /// Endpoint silence after user speech before the turn is considered complete, ms.
    public var endpointDelayMs: Int
    public var semanticGradingEnabled: Bool
    /// Preferred TTS voice quality. Premium voices sound notably more natural
    /// than the default compact voices.
    public var preferredQuality: SettingsStore.VoiceQuality
    /// Transient hint set by the session controller before each utterance so
    /// the synthesizer knows whether to use `questionVoice` or `answerVoice`.
    /// Not persisted.
    public var activeSide: SpeechSide?

    public init(
        questionLocale: String = "en-US",
        answerLocale: String = "en-US",
        questionVoice: String? = nil,
        answerVoice: String? = nil,
        speechRate: Double = 1.0,
        usesDefaultSpeechRate: Bool = true,
        endpointDelayMs: Int = 700,
        semanticGradingEnabled: Bool = false,
        preferredQuality: SettingsStore.VoiceQuality = .auto,
        activeSide: SpeechSide? = nil
    ) {
        self.questionLocale = questionLocale
        self.answerLocale = answerLocale
        self.questionVoice = questionVoice
        self.answerVoice = answerVoice
        self.speechRate = speechRate
        self.usesDefaultSpeechRate = usesDefaultSpeechRate
        self.endpointDelayMs = endpointDelayMs
        self.semanticGradingEnabled = semanticGradingEnabled
        self.preferredQuality = preferredQuality
        self.activeSide = activeSide
    }

    /// The explicitly chosen voice for a side (nil = resolve a default).
    public func explicitVoice(for side: SpeechSide) -> String? {
        switch side {
        case .question: return questionVoice
        case .answer: return answerVoice
        }
    }

    /// Copy of this config tagged with the side about to be spoken.
    public func speaking(_ side: SpeechSide) -> VoiceConfig {
        var copy = self
        copy.activeSide = side
        return copy
    }
}

// MARK: - Note types / notes

public enum NoteTypeKind: Int, Codable, Sendable, Hashable {
    case standard = 0
    case cloze = 1
}

public struct NoteTemplate: Codable, Sendable, Hashable {
    public var name: String
    /// Anki template markup for the question side.
    public var questionFormat: String
    /// Anki template markup for the answer side.
    public var answerFormat: String
    public var ordinal: Int

    public init(name: String, questionFormat: String, answerFormat: String, ordinal: Int) {
        self.name = name
        self.questionFormat = questionFormat
        self.answerFormat = answerFormat
        self.ordinal = ordinal
    }
}

public struct NoteType: Identifiable, Codable, Sendable, Hashable {
    public var id: Int64
    public var name: String
    public var fieldNames: [String]
    public var templates: [NoteTemplate]
    public var kind: NoteTypeKind

    public init(
        id: Int64, name: String, fieldNames: [String],
        templates: [NoteTemplate], kind: NoteTypeKind
    ) {
        self.id = id
        self.name = name
        self.fieldNames = fieldNames
        self.templates = templates
        self.kind = kind
    }

    public static let basic = NoteType(
        id: 1,
        name: "Basic",
        fieldNames: ["Front", "Back"],
        templates: [
            NoteTemplate(
                name: "Card 1",
                questionFormat: "{{Front}}",
                answerFormat: "{{FrontSide}}\n<hr id=answer>\n{{Back}}",
                ordinal: 0
            )
        ],
        kind: .standard
    )

    public static let basicReversed = NoteType(
        id: 2,
        name: "Basic (and reversed card)",
        fieldNames: ["Front", "Back"],
        templates: [
            NoteTemplate(
                name: "Card 1",
                questionFormat: "{{Front}}",
                answerFormat: "{{FrontSide}}\n<hr id=answer>\n{{Back}}",
                ordinal: 0
            ),
            NoteTemplate(
                name: "Card 2",
                questionFormat: "{{Back}}",
                answerFormat: "{{FrontSide}}\n<hr id=answer>\n{{Front}}",
                ordinal: 1
            )
        ],
        kind: .standard
    )
}

public struct Note: Identifiable, Codable, Sendable, Hashable {
    public var id: Int64
    public var noteTypeID: Int64
    /// Field values in note-type order. The first two fields are front/back for basic types.
    public var fields: [String]
    /// Space-separated tags, Anki style.
    public var tags: [String]
    /// Stable identity for future Anki sync compatibility.
    public var guid: String
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: Int64, noteTypeID: Int64, fields: [String], tags: [String],
        guid: String, createdAt: Date = Date(), modifiedAt: Date = Date()
    ) {
        self.id = id
        self.noteTypeID = noteTypeID
        self.fields = fields
        self.tags = tags
        self.guid = guid
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var front: String { fields.first ?? "" }
    public var back: String { fields.count > 1 ? fields[1] : "" }
}

// MARK: - Card

/// A schedulable card generated from a note via a template ordinal.
public struct Card: Identifiable, Codable, Sendable, Hashable {
    public var id: Int64
    public var noteID: Int64
    public var deckID: Int64
    public var templateOrdinal: Int
    public var scheduling: SchedulingState
    public var suspended: Bool
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: Int64, noteID: Int64, deckID: Int64, templateOrdinal: Int,
        scheduling: SchedulingState = SchedulingState(),
        suspended: Bool = false,
        createdAt: Date = Date(), modifiedAt: Date = Date()
    ) {
        self.id = id
        self.noteID = noteID
        self.deckID = deckID
        self.templateOrdinal = templateOrdinal
        self.scheduling = scheduling
        self.suspended = suspended
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// A card joined with its note content — the shape the session engine and UI consume.
public struct StudyCard: Identifiable, Sendable, Hashable {
    public var id: Int64 { card.id }
    public var card: Card
    public var note: Note
    public var noteType: NoteType
    public var deck: Deck

    public init(card: Card, note: Note, noteType: NoteType, deck: Deck) {
        self.card = card
        self.note = note
        self.noteType = noteType
        self.deck = deck
    }
}

// MARK: - Review log

/// How the review was performed — used for hands-free metrics (PRD §31).
public enum StudyMode: Int, Codable, Sendable, Hashable {
    case touch = 0
    case voice = 1
}

public struct ReviewLog: Identifiable, Codable, Sendable, Hashable {
    public var id: Int64
    public var cardID: Int64
    public var rating: Rating
    public var reviewedAt: Date
    /// Wall-clock duration of the review in milliseconds.
    public var durationMs: Int
    public var studyMode: StudyMode
    /// Complete scheduling state before the review (for undo).
    public var previousState: SchedulingState
    /// Complete scheduling state after the review.
    public var newState: SchedulingState

    public init(
        id: Int64, cardID: Int64, rating: Rating, reviewedAt: Date,
        durationMs: Int, studyMode: StudyMode,
        previousState: SchedulingState, newState: SchedulingState
    ) {
        self.id = id
        self.cardID = cardID
        self.rating = rating
        self.reviewedAt = reviewedAt
        self.durationMs = durationMs
        self.studyMode = studyMode
        self.previousState = previousState
        self.newState = newState
    }
}

// MARK: - Voice compatibility (PRD §24)

public enum VoiceCompatibility: Int, Codable, Sendable, Hashable, Comparable {
    case excellent = 0
    case usable = 1
    case visualRequired = 2
    case unsupported = 3

    public static func < (lhs: VoiceCompatibility, rhs: VoiceCompatibility) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Cards below this level are skipped in hands-free sessions by default.
    public static let handsFreeCutoff: VoiceCompatibility = .visualRequired

    public var title: String {
        switch self {
        case .excellent: return "Excellent"
        case .usable: return "Usable"
        case .visualRequired: return "Visual required"
        case .unsupported: return "Unsupported"
        }
    }
}
