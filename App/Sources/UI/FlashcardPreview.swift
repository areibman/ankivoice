import SwiftUI
import NaturalLanguage

/// A swipeable stack of sample flashcards: tap to flip, tap the speaker to
/// hear the card read in its own language. Used on the AnkiWeb deck page so
/// people can judge a deck — and how it will *sound* — before importing.
struct FlashcardPreview: View {
    struct Card: Identifiable, Hashable {
        struct Side: Hashable {
            /// Field label, e.g. "Meaning". Empty for the primary field.
            let label: String
            let text: String
        }
        let id: Int
        let front: Side
        let back: [Side]

        var frontLanguage: String { LanguageGuess.locale(for: front.text) }
        var backLanguage: String { LanguageGuess.locale(for: back.map(\.text).joined(separator: "\n")) }
    }

    let cards: [Card]

    @State private var index = 0
    @State private var flipped: Set<Int> = []
    @State private var speakingCard: Int?
    @State private var tts = TextToSpeech()
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $index) {
                ForEach(cards) { card in
                    cardFace(card)
                        .padding(.horizontal, 2)
                        .tag(card.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 230)
            .onChange(of: index) { _, _ in
                tts.stopSpeaking()
                speakingCard = nil
            }

            HStack(spacing: 6) {
                ForEach(cards) { card in
                    Capsule()
                        .fill(card.id == index ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: card.id == index ? 18 : 6, height: 6)
                        .animation(.snappy, value: index)
                }
            }
            .accessibilityHidden(true)
        }
        .onDisappear { tts.stopSpeaking() }
    }

    // MARK: Card face

    private func cardFace(_ card: Card) -> some View {
        let isFlipped = flipped.contains(card.id)
        return ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(isFlipped ? "BACK" : "FRONT")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(card.id + 1) of \(cards.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Button {
                        speak(card, side: isFlipped ? .back : .front)
                    } label: {
                        Image(systemName: speakingCard == card.id ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(speakingCard == card.id ? "Stop" : "Listen")
                    .accessibilityIdentifier("preview.listen")
                }

                ScrollView(showsIndicators: false) {
                    if isFlipped {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(card.back.enumerated()), id: \.offset) { _, side in
                                VStack(alignment: .leading, spacing: 2) {
                                    if !side.label.isEmpty {
                                        Text(Self.humanized(side.label))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(side.text)
                                        .font(card.back.count == 1 ? .title3 : .body)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(card.front.text)
                            .font(card.front.text.count > 60 ? .body : .title2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text(isFlipped ? "Tap to see the front" : "Tap to reveal the answer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            // The container rotates 180° when flipped; mirror the content
            // back so it reads normally on the far side.
            .scaleEffect(x: isFlipped ? -1 : 1, y: 1)
        }
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(duration: 0.4)) {
                if isFlipped { flipped.remove(card.id) } else { flipped.insert(card.id) }
            }
            tts.stopSpeaking()
            speakingCard = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isFlipped ? "Back: \(card.back.map(\.text).joined(separator: ". "))" : "Front: \(card.front.text)")
        .accessibilityHint("Double-tap to flip")
    }

    private enum Side { case front, back }

    private func speak(_ card: Card, side: Side) {
        if speakingCard == card.id {
            tts.stopSpeaking()
            speakingCard = nil
            return
        }
        let text: String
        let locale: String
        switch side {
        case .front:
            text = card.front.text
            locale = card.frontLanguage
        case .back:
            text = card.back.map(\.text).joined(separator: ". ")
            locale = card.backLanguage
        }
        guard !text.isEmpty else { return }
        speakingCard = card.id
        let rate = services.settings.speechRate
        let preferredVoice = services.settings.defaultVoice(forLocale: locale)
        Task {
            await tts.previewText(text, locale: locale, rate: rate, preferredVoice: preferredVoice)
            if speakingCard == card.id { speakingCard = nil }
        }
    }

    // MARK: Building cards from AnkiWeb samples

    /// Builds preview cards from AnkiWeb's sample notes.
    ///
    /// Shared decks rarely put the question first: many lead with an index,
    /// an ID, a frequency rank or media filenames, and elaborate note types
    /// (Jlab, Core 2k/6k…) have dozens of generated helper fields. Field
    /// names are scored so the most prompt-like field becomes the front and
    /// the most answer-like fields become the back, in the deck's own order.
    static func cards(from samples: [AnkiWebClient.SampleNote], limit: Int = 6, maxBackFields: Int = 3) -> [Card] {
        var out: [Card] = []
        for sample in samples {
            let fields = sample.fields
                .map { Card.Side(label: $0.name, text: previewText($0.value)) }
                .filter { !$0.text.isEmpty }
            guard !fields.isEmpty else { continue }

            // (field, front score, back priority) for everything worth showing.
            // If every field looks like bookkeeping, show them all rather than nothing.
            var scored: [(side: Card.Side, front: Int, back: Int)] = fields.compactMap { side in
                guard let role = FieldRole(side) else { return nil }
                return (side, role.frontScore, role.backPriority)
            }
            if scored.isEmpty {
                scored = fields.map { ($0, FieldRole.neutral.frontScore, FieldRole.neutral.backPriority) }
            }
            let bestScore = scored.map(\.front).max()!
            // Earliest field with the best score wins ties (deck authors put
            // the main prompt before its variants).
            let front = scored.first(where: { $0.front == bestScore })!.side

            var seen: Set<String> = [normalized(front.text)]
            var back: [Card.Side] = []
            let ordered = scored
                .filter { $0.side != front }
                .enumerated()
                .sorted { a, b in
                    if a.element.back != b.element.back { return a.element.back > b.element.back }
                    return a.offset < b.offset
                }
                .map(\.element.side)
            for side in ordered where seen.insert(normalized(side.text)).inserted {
                back.append(side)
                if back.count == maxBackFields { break }
            }
            out.append(Card(
                id: out.count,
                front: Card.Side(label: "", text: front.text),
                back: back.isEmpty ? [Card.Side(label: "", text: "(no answer field)")] : back
            ))
            if out.count == limit { break }
        }
        return out
    }

    /// What a note field is for, judged from its name (and, for
    /// housekeeping, its value). `nil` means "never show this".
    enum FieldRole {
        case prompt, answer, extra, neutral

        /// Bookkeeping and generated helper fields: never shown.
        private static let hidden: Set<String> = [
            "id", "uid", "guid", "index", "idx", "number", "no", "num", "order", "rank", "frequency", "freq",
            "sort", "sortfield", "seq", "sequence", "position", "version", "tags", "tag", "url", "link", "links",
            "source", "sources", "references", "reference", "audio", "sound", "image", "images", "picture",
            "img", "media", "metadata", "lookup", "cloze", "listening", "spaced", "lemma", "html", "css",
        ]
        private static let promptWords: Set<String> = [
            "front", "question", "expression", "word", "words", "kanji", "vocab", "vocabulary", "term",
            "prompt", "target", "sentence", "text", "hanzi", "hangul", "phrase", "example", "simplified",
            "traditional", "japanese", "spanish", "french", "german", "chinese", "korean", "italian",
            "portuguese", "russian", "latin", "arabic", "hebrew", "hindi", "thai", "vietnamese", "dutch",
            "swedish", "norwegian", "finnish", "polish", "turkish", "greek", "verb", "noun", "adjective",
        ]
        private static let answerWords: Set<String> = [
            "back", "answer", "meaning", "meanings", "translation", "definition", "definitions", "english",
            "reading", "hiragana", "katakana", "pinyin", "romaji", "furigana", "gloss", "pronunciation",
            "ipa", "explanation", "synonyms",
        ]
        private static let extraWords: Set<String> = [
            "remarks", "remark", "notes", "note", "extra", "hint", "hints", "mnemonic", "comment", "comments",
            "context", "usage", "grammar", "info", "details", "description", "other",
        ]

        init?(_ side: Card.Side) {
            let tokens = Self.tokens(in: side.label)
            if tokens.contains(where: { Self.hidden.contains($0) }) { return nil }
            if Self.looksLikeHousekeeping(side.text) { return nil }
            if tokens.contains(where: { Self.promptWords.contains($0) }) { self = .prompt; return }
            if tokens.contains(where: { Self.answerWords.contains($0) }) { self = .answer; return }
            if tokens.contains(where: { Self.extraWords.contains($0) }) { self = .extra; return }
            self = .neutral
        }

        var frontScore: Int {
            switch self {
            case .prompt: return 3
            case .neutral: return 1
            case .answer: return 0
            case .extra: return -1
            }
        }

        var backPriority: Int {
            switch self {
            case .answer: return 3
            case .neutral: return 2
            case .prompt: return 1
            case .extra: return 0
            }
        }

        /// Splits "Jlab-KanjiSpaced", "Other_Front", "RemarksBack" into words.
        static func tokens(in name: String) -> [String] {
            var spaced = ""
            var previous: Character?
            for character in name {
                if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                    spaced.append(" ")
                }
                spaced.append(character)
                previous = character
            }
            return spaced
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }

        static func looksLikeHousekeeping(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Purely numeric ("14", "1,203", "3.5") is an index, not a prompt.
            if trimmed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) || ",.-".unicodeScalars.contains($0) }) {
                return true
            }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return true }
            // Bare media filenames aren't readable prompts.
            return trimmed.range(
                of: #"^\S+\.(mp3|ogg|wav|m4a|jpg|jpeg|png|gif|svg|webp)$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    /// HTML → readable preview text: strips markup and sound tags, drops
    /// Anki furigana readings (`漢字[かんじ]` → `漢字`), the invisible word
    /// separators some Japanese decks use, and the spaces furigana markup
    /// needs between kanji (`授 業 中` → `授業中`).
    static func previewText(_ html: String) -> String {
        var text = AnkiWebClient.DeckInfo.plainText(fromHTML: html)
        text = text.replacingOccurrences(of: #"\[(?:sound|image|anki):[^\]]*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: #"(?<=[^\s\[\]])\[[\p{Hiragana}\p{Katakana}ー・\s]+\]"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "\u{205F}", with: "")
        text = text.replacingOccurrences(
            of: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}ー。、])[ \t]+(?=[\p{Han}\p{Hiragana}\p{Katakana}ー。、])"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "RemarksBack" → "REMARKS BACK", "Jlab-Hiragana" → "JLAB HIRAGANA".
    static func humanized(_ fieldName: String) -> String {
        let words = FieldRole.tokens(in: fieldName)
        return words.isEmpty ? fieldName.uppercased() : words.joined(separator: " ").uppercased()
    }

    /// Key for spotting the same content in two fields (e.g. "何 やってた の"
    /// vs "何やってたの").
    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}

/// Best-effort language detection for speaking arbitrary text.
enum LanguageGuess {
    /// Returns a BCP-47 tag suited to voice selection, e.g. "ja-JP".
    static func locale(for text: String, fallback: String = "en-US") -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return fallback }
        return Self.regionalTag(for: language.rawValue, fallback: fallback)
    }

    /// Maps a bare language code to the most common region so voice lookup
    /// prefers the expected accent.
    static func regionalTag(for code: String, fallback: String) -> String {
        switch code {
        case "en": return fallback.hasPrefix("en") ? fallback : "en-US"
        case "ja": return "ja-JP"
        case "zh-Hans", "zh": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "ko": return "ko-KR"
        case "de": return "de-DE"
        case "fr": return "fr-FR"
        case "es": return "es-ES"
        case "it": return "it-IT"
        case "pt": return "pt-BR"
        case "ru": return "ru-RU"
        case "nl": return "nl-NL"
        case "sv": return "sv-SE"
        case "da": return "da-DK"
        case "nb": return "nb-NO"
        case "fi": return "fi-FI"
        case "pl": return "pl-PL"
        case "tr": return "tr-TR"
        case "ar": return "ar-SA"
        case "he": return "he-IL"
        case "hi": return "hi-IN"
        case "th": return "th-TH"
        case "vi": return "vi-VN"
        case "id": return "id-ID"
        case "el": return "el-GR"
        case "cs": return "cs-CZ"
        case "hu": return "hu-HU"
        case "ro": return "ro-RO"
        case "uk": return "uk-UA"
        default: return code
        }
    }
}
