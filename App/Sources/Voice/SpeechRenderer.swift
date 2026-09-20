import Foundation

/// Renders card content into speakable text (PRD §25).
///
/// Input: card HTML (Anki-style, possibly with cloze markers, `<br>`, `<img>`,
/// `[sound:...]` references, furigana and MathJax).
/// Output: ordered `SpeechSegment`s — synthesized speech with locale, pauses,
/// and pre-recorded media playback.
///
/// What is spoken is the card, not the note type's tutorial. Field filters
/// (`furigana:`, `kana:`, conditionals) are expanded, and fields that are
/// notes, hints or remarks are left on screen but not read aloud. The study
/// screen uses `face` when that on-screen card and the spoken words diverge.
public struct SpeechRenderer: Sendable {

    public init() {}

    // MARK: - Segments

    public enum Side: Sendable, Hashable {
        case question
        case answer
    }

    public enum Segment: Sendable, Hashable {
        /// Text to synthesize, tagged with its BCP-47 locale.
        case speech(text: String, locale: String)
        /// A pause in seconds (used for `<br>` and cloze gaps).
        case pause(seconds: TimeInterval)
        /// A recorded media file to play instead of synthesizing.
        case media(filename: String)
    }

    public struct RenderedCard: Sendable, Hashable {
        public var question: [Segment]
        public var answer: [Segment]

        public init(question: [Segment], answer: [Segment]) {
            self.question = question
            self.answer = answer
        }
    }

    /// On-screen card versus the words the voice will actually say.
    public struct RenderedFace: Sendable, Equatable {
        /// HTML for the card face (ruby, images, styled math).
        public var html: String
        /// The note type's stylesheet. Empty when the card has no custom layout.
        public var css: String
        /// Anki's card classes, e.g. "card card1".
        public var cardClass: String
        /// Exact text read aloud, one line per spoken chunk.
        public var spokenText: String
        /// True when formatted markup, math, furigana or a notes section means
        /// the visible card is not the same as the spoken words.
        public var readAloudDiffers: Bool
        /// True when the face needs an HTML renderer rather than a plain label.
        public var isRich: Bool
    }

    // MARK: - Rendering

    /// Renders a study card for speech using per-deck locales. Recorded
    /// audio referenced by `[sound:…]` tags is played before the synthesized
    /// text (PRD §26); missing files are skipped at playback time.
    ///
    /// A side is one locale and therefore one voice. Splitting a card into
    /// script runs made foreign decks hop between speakers on every field.
    public func render(_ card: StudyCard, questionLocale: String, answerLocale: String) -> RenderedCard {
        let (questionText, questionMedia) = Self.speechPieces(for: card, side: .question)
        let (answerText, answerMedia) = Self.speechPieces(for: card, side: .answer)
        return RenderedCard(
            question: questionMedia.map { .media(filename: $0) }
                + segments(fromText: questionText, locale: questionLocale),
            answer: answerMedia.map { .media(filename: $0) }
                + segments(fromText: answerText, locale: answerLocale)
        )
    }

    /// Display HTML and the matching spoken words for one side.
    public func face(
        _ card: StudyCard,
        side: Side,
        questionLocale: String,
        answerLocale: String
    ) -> RenderedFace {
        let html = Self.prepareDisplay(Self.templateOutput(for: card, side: side, mode: .display))
        let rendered = render(card, questionLocale: questionLocale, answerLocale: answerLocale)
        let segments = side == .question ? rendered.question : rendered.answer
        var spoken = Self.plainText(of: segments)
        if spoken.isEmpty, html.range(of: "<img", options: .caseInsensitive) != nil {
            spoken = "This side is a picture, so nothing is read aloud."
        }
        let questionPlain = side == .answer
            ? HTMLText.plain(Self.prepareDisplay(Self.templateOutput(for: card, side: .question, mode: .display)))
            : ""
        let rich = html.contains("<")
        return RenderedFace(
            html: html,
            css: card.noteType.css,
            cardClass: "card card\(card.card.templateOrdinal + 1)",
            spokenText: spoken,
            readAloudDiffers: Self.readAloudDiffers(html: html, spoken: spoken, repeatedQuestion: questionPlain),
            isRich: rich
        )
    }

    /// Joins spoken chunks, dropping pauses and media. This is the text the
    /// "Read aloud" view shows.
    public static func plainText(of segments: [Segment]) -> String {
        segments.compactMap { segment in
            if case .speech(let text, _) = segment {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }.joined(separator: "\n")
    }

    private func segments(fromText text: String, locale: String) -> [Segment] {
        guard !text.isEmpty else { return [] }
        var result: [Segment] = []
        for part in text.split(separator: "\u{2028}", omittingEmptySubsequences: true) {
            if !result.isEmpty { result.append(.pause(seconds: 0.35)) }
            let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(.speech(text: trimmed, locale: locale))
            }
        }
        return result
    }

    // MARK: - Template expansion

    private enum Mode {
        case speech
        case display
    }

    /// Minimal Anki-template expansion: field substitutions, `{{#Field}}` /
    /// `{{^Field}}` conditionals, and the filters shared decks actually use
    /// (`furigana:`, `kana:`, `kanji:`, `text:`, `cloze:`, `hint:`).
    private static func templateOutput(for card: StudyCard, side: Side, mode: Mode) -> String {
        let noteType = card.noteType
        let template = noteType.templates.first { $0.ordinal == card.card.templateOrdinal }
            ?? noteType.templates.first
        var format: String
        if let template {
            format = side == .question ? template.questionFormat : template.answerFormat
        } else if noteType.fieldNames.count >= 2 {
            format = side == .question ? "{{" + noteType.fieldNames[0] + "}}"
                                       : "{{" + noteType.fieldNames[1] + "}}"
        } else {
            format = side == .question ? (card.note.fields.first ?? "") : (card.note.fields.last ?? "")
        }

        // {{FrontSide}} echoes the question. Speech already said it; the
        // on-screen answer still shows it, the way Anki does.
        if mode == .display && side == .answer {
            let front = templateOutput(for: card, side: .question, mode: .display)
            format = format.replacingOccurrences(of: "{{FrontSide}}", with: front)
        } else {
            format = format.replacingOccurrences(of: "{{FrontSide}}", with: "")
        }

        let templateName = template?.name ?? ""
        format = stripConditionals(format) { key, inverted in
            let value = resolveDirective(key, card: card, side: side, mode: mode, templateName: templateName)
            let empty = HTMLText.plain(value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return inverted ? empty : !empty
        }
        format = replace(pattern: #"\{\{(?!c\d+::)([^}]+)\}\}"#, in: format) { directive in
            resolveDirective(directive, card: card, side: side, mode: mode, templateName: templateName)
        }
        if noteType.kind == .cloze || format.contains("{{c") {
            format = expandClozes(
                in: format,
                reveal: side == .answer,
                activeOrdinal: template?.ordinal ?? card.card.templateOrdinal
            )
        }
        return format
    }

    /// Speech for one side, plus any `[sound:]` files.
    ///
    /// Cloze cards speak the cloze sentence. Everything else speaks one field
    /// per side — the word on the front, the meaning on the back. The rest of
    /// an Anki template (frequency rank, part of speech, deck credits, notes,
    /// example sentences) stays on screen and is not read.
    private static func speechPieces(for card: StudyCard, side: Side) -> (String, [String]) {
        if card.noteType.kind == .cloze {
            return templateSpeech(for: card, side: side)
        }
        let referenced = referencedSpeechFields(for: card, side: side)
        let chosen = pickSpeechField(referenced, side: side) ?? fallbackSpeech(card, side: side)
        let (text, media) = extract(html: prepareSpeech(chosen), clozeAnswer: side == .answer)
        var sounds = media
        for field in referenced where isAudioName(field.name) {
            let (_, more) = extract(html: field.value, clozeAnswer: false)
            for name in more where !sounds.contains(name) {
                sounds.append(name)
            }
        }
        return (text, sounds)
    }

    private static func templateSpeech(for card: StudyCard, side: Side) -> (String, [String]) {
        let html = prepareSpeech(templateOutput(for: card, side: side, mode: .speech))
        let (text, media) = extract(html: html, clozeAnswer: side == .answer)
        let asides = asidePlainTexts(card).filter { $0.count >= 12 }
        let chunks = text.split(separator: "\u{2028}", omittingEmptySubsequences: false).map(String.init)
        let kept = chunks.filter { chunk in
            let folded = collapsed(chunk)
            guard folded.count >= 8 else { return true }
            return !asides.contains { aside in
                let needle = collapsed(aside)
                return folded.contains(needle) || needle.contains(folded)
            }
        }
        let cleaned = kept.joined(separator: "\u{2028}")
        if shouldFallback(cleaned, card: card, side: side) {
            return (fallbackSpeech(card, side: side), media)
        }
        return (cleaned, media)
    }

    private struct SpeechField {
        var name: String
        var value: String
    }

    /// Fields the template actually shows on this side, in template order,
    /// after empty conditionals are removed. Static HTML ("based on iKnow",
    /// frequency captions) is not a field and is ignored.
    private static func referencedSpeechFields(for card: StudyCard, side: Side) -> [SpeechField] {
        let noteType = card.noteType
        let template = noteType.templates.first { $0.ordinal == card.card.templateOrdinal }
            ?? noteType.templates.first
        let format: String
        if let template {
            format = side == .question ? template.questionFormat : template.answerFormat
        } else if noteType.fieldNames.count >= 2 {
            format = side == .question ? "{{" + noteType.fieldNames[0] + "}}" : "{{" + noteType.fieldNames[1] + "}}"
        } else {
            return []
        }
        let visible = stripConditionals(format) { key, inverted in
            let value = resolveDirective(key, card: card, side: side, mode: .speech, templateName: "")
            let empty = HTMLText.plain(value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return inverted ? empty : !empty
        }
        guard let regex = try? NSRegularExpression(pattern: #"\{\{(?!c\d+::)([^}]+)\}\}"#) else { return [] }
        let ns = visible as NSString
        var seen: Set<String> = []
        var fields: [SpeechField] = []
        for match in regex.matches(in: visible, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let directive = ns.substring(with: match.range(at: 1))
            let (_, name) = splitDirective(directive)
            let specials = ["FrontSide", "Tags", "Deck", "Subdeck", "Type", "Card"]
            if specials.contains(name) || isAsideField(name, value: lookupField(name, card: card)) {
                continue
            }
            if isMetadataName(name) && !isAudioName(name) { continue }
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            let value = resolveDirective(directive, card: card, side: side, mode: .speech, templateName: "")
            let speakable = HTMLText.plain(value).trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSound = value.lowercased().contains("[sound:")
            guard !speakable.isEmpty || hasSound else { continue }
            fields.append(SpeechField(name: name, value: value))
        }
        return fields
    }

    /// One field: the word on the question, the meaning on the answer.
    private static func pickSpeechField(_ fields: [SpeechField], side: Side) -> String? {
        guard !fields.isEmpty else { return nil }
        switch side {
        case .question:
            let prompts = fields.filter { promptRank($0.name) > 0 }
            guard let best = prompts.map({ promptRank($0.name) }).max() else { return nil }
            return prompts.first { promptRank($0.name) == best }?.value
        case .answer:
            let ranked = fields.filter { answerRank($0.name) > 0 }
            // A reversed card's answer is {{Front}}. The name isn't "meaning",
            // so when nothing scores as an answer, speak the first real field.
            let pool = ranked.isEmpty ? fields.filter { !isAudioName($0.name) && !isMetadataName($0.name) } : ranked
            guard let best = pool.map({ answerRank($0.name) }).max() else { return nil }
            return pool.first { answerRank($0.name) == best }?.value
        }
    }

    private static let metadataTokens: Set<String> = [
        "index", "idx", "rank", "frequency", "freq", "pos", "caution", "jlpt",
        "metadata", "id", "uid", "number", "order", "sequence", "version",
        "source", "sources", "credit", "credits", "url", "link", "audio", "sound", "image",
    ]

    private static func isMetadataName(_ name: String) -> Bool {
        let tokens = FlashcardPreview.FieldRole.tokens(in: name)
        if tokens.contains(where: { metadataTokens.contains($0) }) { return true }
        return tokens.contains("part") && tokens.contains("speech")
    }

    private static func isAudioName(_ name: String) -> Bool {
        let tokens = FlashcardPreview.FieldRole.tokens(in: name)
        return tokens.contains("audio") || tokens.contains("sound")
    }

    private static func promptRank(_ name: String) -> Int {
        if isMetadataName(name) { return -1 }
        let tokens = FlashcardPreview.FieldRole.tokens(in: name)
        if tokens.contains(where: { ["expression", "kanji", "word", "vocab", "vocabulary", "front", "question", "term", "prompt"].contains($0) }) {
            return 3
        }
        return 1
    }

    private static func answerRank(_ name: String) -> Int {
        if isMetadataName(name) { return -1 }
        let tokens = FlashcardPreview.FieldRole.tokens(in: name)
        let meaning = ["meaning", "translation", "definition", "gloss", "english", "answer", "back"]
        if tokens.contains(where: { meaning.contains($0) }) && !tokens.contains(where: { ["sentence", "example"].contains($0) }) {
            return 5
        }
        if tokens.contains(where: { ["reading", "kana", "hiragana", "romaji", "pinyin"].contains($0) }) {
            return 2
        }
        if tokens.contains(where: { ["sentence", "example"].contains($0) }) { return 1 }
        return 0
    }

    private static func shouldFallback(_ spoken: String, card: StudyCard, side: Side) -> Bool {
        if spoken.contains("{{") { return true }
        let said = collapsed(spoken)
        let asides = asidePlainTexts(card).map(collapsed).filter { $0.count >= 12 }
        let asideHit = asides.contains { said.contains($0) }
        let wanted = collapsed(fallbackSpeech(card, side: side))
        if said.isEmpty {
            // Empty because the template drew only a picture: don't invent a
            // sentence from another field. Empty because the notes were the
            // only thing left after a missed filter: read the real card.
            return asideHit || (wanted.count >= 2 && !asides.isEmpty)
        }
        guard asideHit, wanted.count >= 2 else { return false }
        return !said.contains(wanted)
    }

    /// Prompt field for the question, meaning/reading fields for the answer.
    /// Bookkeeping (index, audio filename) and notes stay out.
    private static func fallbackSpeech(_ card: StudyCard, side: Side) -> String {
        struct Candidate {
            var name: String
            var text: String
            var role: FlashcardPreview.FieldRole
        }
        var ranked: [Candidate] = []
        for (index, name) in card.noteType.fieldNames.enumerated() {
            if isMetadataName(name) { continue }
            let raw = index < card.note.fields.count ? card.note.fields[index] : ""
            let plain = kanaReadings(speakMath(HTMLText.plain(raw)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { continue }
            guard let role = FlashcardPreview.FieldRole(
                FlashcardPreview.Card.Side(label: name, text: plain)
            ) else { continue }
            if case .extra = role { continue }
            ranked.append(Candidate(name: name, text: plain, role: role))
        }
        func rank(_ role: FlashcardPreview.FieldRole) -> Int {
            switch role {
            case .prompt: return 3
            case .neutral: return 1
            case .meaning, .reading: return 0
            case .extra: return -1
            }
        }
        switch side {
        case .question:
            let prompts = ranked.filter {
                if case .prompt = $0.role { return true }
                if case .neutral = $0.role { return true }
                return false
            }
            guard let best = prompts.map({ rank($0.role) }).max() else { return "" }
            return prompts.first { rank($0.role) == best }?.text ?? ""
        case .answer:
            let meanings = ranked.filter {
                if case .meaning = $0.role { return true }
                if case .reading = $0.role { return true }
                return false
            }
            if let best = meanings.max(by: { answerRank($0.name) < answerRank($1.name) }) {
                return best.text
            }
            return ranked.first { $0.text.count < 80 }?.text ?? ""
        }
    }

    private static func asidePlainTexts(_ card: StudyCard) -> [String] {
        card.noteType.fieldNames.enumerated().compactMap { index, name in
            let value = index < card.note.fields.count ? card.note.fields[index] : ""
            guard isAsideField(name, value: value) else { return nil }
            let plain = kanaReadings(HTMLText.plain(value)).trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? nil : plain
        }
    }

    /// Notes, hints, remarks and the other fields shared decks use for the
    /// tutorial — shown on the card, not spoken.
    private static func isAsideField(_ name: String, value: String) -> Bool {
        if value.lowercased().contains("[sound:") { return false }
        let plain = HTMLText.plain(value)
        let probe = plain.isEmpty ? "placeholder" : plain
        guard let role = FlashcardPreview.FieldRole(
            FlashcardPreview.Card.Side(label: name, text: probe)
        ) else { return false }
        if case .extra = role { return true }
        return false
    }

    private static func lookupField(_ name: String, card: StudyCard) -> String {
        let names = card.noteType.fieldNames
        let index = names.firstIndex(of: name)
            ?? names.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
        guard let index, index < card.note.fields.count else { return "" }
        return card.note.fields[index]
    }

    /// `furigana:Expression` → (`furigana`, `Expression`). A bare name has no filter.
    private static func splitDirective(_ raw: String) -> (filter: String?, field: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return (nil, trimmed) }
        let head = String(trimmed[..<colon]).lowercased()
        let known = ["text", "furigana", "kana", "kanji", "hint", "type", "cloze", "edit"]
        guard known.contains(head) || head.hasPrefix("tts") else { return (nil, trimmed) }
        let field = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (head.hasPrefix("tts") ? "tts" : head, field)
    }

    private static func resolveDirective(
        _ directive: String, card: StudyCard, side: Side, mode: Mode, templateName: String
    ) -> String {
        let trimmed = directive.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("^") || trimmed.hasPrefix("/") { return "" }
        let (filter, field) = splitDirective(trimmed)
        switch field {
        case "Tags":
            return mode == .speech ? "" : card.note.tags.joined(separator: ", ")
        case "Deck":
            return mode == .speech ? "" : card.deck.fullName
        case "Subdeck":
            return mode == .speech ? "" : card.deck.name
        case "Type":
            return mode == .speech ? "" : card.noteType.name
        case "Card":
            return mode == .speech ? "" : templateName
        case "FrontSide":
            return ""
        default:
            break
        }
        let value = lookupField(field, card: card)
        if mode == .speech, isAsideField(field, value: value) { return "" }
        switch filter {
        case "hint":
            if mode == .speech || value.isEmpty { return "" }
            return "<div class=\"anki-hint\">\(value)</div>"
        case "type":
            // Anki shows a typing box on the question. Putting the field
            // here would print the answer on the front of the card.
            if mode == .speech || side == .question { return "" }
            return value
        case "text":
            return HTMLText.plain(value)
        case "kana":
            return kanaReadings(value)
        case "kanji":
            return kanjiReadings(value)
        case "furigana":
            return mode == .speech ? kanaReadings(value) : rubyReadings(value)
        default:
            return value
        }
    }

    /// `{{#Field}}…{{/Field}}` and `{{^Field}}…{{/Field}}`, innermost first.
    private static func stripConditionals(
        _ input: String,
        keep: (_ key: String, _ inverted: Bool) -> Bool
    ) -> String {
        var text = input
        for _ in 0..<64 {
            guard let closeRegex = try? NSRegularExpression(pattern: #"\{\{/([^}]+)\}\}"#) else { break }
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let close = closeRegex.firstMatch(in: text, range: range),
                  let closeRange = Range(close.range, in: text) else { break }
            let key = ns.substring(with: close.range(at: 1))
            let escaped = NSRegularExpression.escapedPattern(for: key)
            guard let openRegex = try? NSRegularExpression(pattern: "\\{\\{([#^])\(escaped)\\}\\}") else { break }
            let opens = openRegex.matches(in: text, range: NSRange(location: 0, length: close.range.location))
            guard let open = opens.last, let openRange = Range(open.range, in: text) else {
                text.removeSubrange(closeRange)
                continue
            }
            let inverted = ns.substring(with: open.range(at: 1)) == "^"
            let body = String(text[openRange.upperBound..<closeRange.lowerBound])
            let replacement = keep(key, inverted) ? body : ""
            text.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: replacement)
        }
        return text
    }

    // MARK: - Display vs speech cleanup

    private static func prepareSpeech(_ html: String) -> String {
        var text = stripAsideElements(html)
        text = transformMath(text, speech: true)
        text = kanaReadings(text)
        return text
    }

    private static func prepareDisplay(_ html: String) -> String {
        var text = stripDangerousTags(html)
        text = transformMath(text, speech: false)
        text = rubyReadings(text)
        // Audio is played, not printed. Leftover [sound:] tags were showing
        // up as the card text on listening templates.
        text = text.replacingOccurrences(
            of: #"\[sound:[^\]]*\]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return text
    }

    /// Drops elements whose class or id marks them as the deck's notes /
    /// tutorial, so a static "How to use this deck" block isn't read.
    private static func stripAsideElements(_ html: String) -> String {
        let pattern = #"(?is)<(div|span|p|section|aside|small)\b[^>]*\b(?:class|id)\s*=\s*["'][^"']*\b(?:notes|note|extra|hint|mnemonic|remarks|instructions|tutorial|readme|credits?)\b[^"']*["'][^>]*>.*?</\1>"#
        return replace(pattern: pattern, in: html) { _ in " " }
    }

    private static func stripDangerousTags(_ html: String) -> String {
        var text = replace(pattern: #"(?is)<(script|iframe|object|embed)\b[^>]*>.*?</\1>"#, in: html) { _ in "" }
        text = replace(pattern: #"(?is)<(script|iframe|object|embed)\b[^>]*/>"#, in: text) { _ in "" }
        text = text.replacingOccurrences(
            of: #"\son\w+\s*=\s*("[^"]*"|'[^']*')"#,
            with: "",
            options: .regularExpression
        )
        return text
    }

    private static func readAloudDiffers(html: String, spoken: String, repeatedQuestion: String) -> Bool {
        if isNonStandard(html) { return true }
        var visible = collapsed(HTMLText.plain(html))
        let said = collapsed(spoken)
        let question = collapsed(repeatedQuestion)
        if !question.isEmpty {
            visible = collapsed(visible.replacingOccurrences(of: question, with: " "))
        }
        if visible.isEmpty && said.isEmpty { return false }
        return visible != said
    }

    private static func isNonStandard(_ html: String) -> Bool {
        let lower = html.lowercased()
        if lower.contains("<img") || lower.contains("<ruby") || lower.contains("<table") || lower.contains("<svg") {
            return true
        }
        if lower.contains("class=\"math") || lower.contains("class=\"anki-") { return true }
        if lower.contains("class=\"notes") || lower.contains("class='notes") { return true }
        return false
    }

    private static func collapsed(_ text: String) -> String {
        text.lowercased()
            .split { $0.isWhitespace || $0 == "\u{2028}" }
            .joined(separator: " ")
    }

    // MARK: - Furigana

    /// `漢字[かんじ]` readings. The base must sit against the bracket so
    /// `[sound:…]` and English "[I mean]" are left alone.
    private static let readingPattern = #"([^\[\]<>\s]+)\[([\p{Hiragana}\p{Katakana}ー・]+)\]"#

    static func kanaReadings(_ text: String) -> String {
        rewrite(pattern: readingPattern, in: text) { ns, match in
            guard match.numberOfRanges > 2 else { return ns.substring(with: match.range) }
            return ns.substring(with: match.range(at: 2))
        }
    }

    private static func kanjiReadings(_ text: String) -> String {
        rewrite(pattern: readingPattern, in: text) { ns, match in
            guard match.numberOfRanges > 1 else { return ns.substring(with: match.range) }
            return ns.substring(with: match.range(at: 1))
        }
    }

    private static func rubyReadings(_ text: String) -> String {
        rewrite(pattern: readingPattern, in: text) { ns, match in
            guard match.numberOfRanges > 2 else { return ns.substring(with: match.range) }
            let base = escapeHTML(ns.substring(with: match.range(at: 1)))
            let reading = escapeHTML(ns.substring(with: match.range(at: 2)))
            return "<ruby>\(base)<rt>\(reading)</rt></ruby>"
        }
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Math / LaTeX

    /// Anki MathJax (`[$]…[/$]`, `[$$]…[/$$]`) and legacy `[latex]` blocks.
    /// Speech gets a readable approximation; the card shows a set-off formula
    /// so it's obvious this isn't plain prose.
    private static func transformMath(_ text: String, speech: Bool) -> String {
        var result = text
        let patterns: [(String, Bool)] = [
            (#"(?s)\[\$\$\](.*?)\[/\$\$\]"#, true),
            (#"(?s)\[\$\](.*?)\[/\$\]"#, false),
            (#"(?s)\[latex\](.*?)\[/latex\]"#, true),
            (#"(?s)\\\((.*?)\\\)"#, false),
            (#"(?s)\\\[(.*?)\\\]"#, true),
        ]
        for (pattern, block) in patterns {
            result = rewrite(pattern: pattern, options: [.dotMatchesLineSeparators], in: result) { ns, match in
                let inner = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                    ? ns.substring(with: match.range(at: 1))
                    : ""
                if speech { return speakMath(inner) }
                let tag = block ? "div" : "span"
                return "<\(tag) class=\"math\">\(escapeHTML(prettyMath(inner)))</\(tag)>"
            }
        }
        return result
    }

    static func speakMath(_ latex: String) -> String {
        var s = latex
        s = rewrite(pattern: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, in: s) { ns, match in
            let a = ns.substring(with: match.range(at: 1))
            let b = ns.substring(with: match.range(at: 2))
            return " \(speakMath(a)) over \(speakMath(b)) "
        }
        s = rewrite(pattern: #"\\sqrt\{([^{}]*)\}"#, in: s) { ns, match in
            " square root of \(speakMath(ns.substring(with: match.range(at: 1)))) "
        }
        s = rewrite(pattern: #"\\(?:text|mathrm|mathbf|mathit)\{([^{}]*)\}"#, in: s) { ns, match in
            " \(ns.substring(with: match.range(at: 1))) "
        }
        for (command, word) in spokenSymbols {
            s = s.replacingOccurrences(of: command, with: word)
        }
        s = s.replacingOccurrences(of: "^2", with: " squared")
        s = s.replacingOccurrences(of: "^3", with: " cubed")
        s = rewrite(pattern: #"\^\{([^{}]*)\}"#, in: s) { ns, match in
            " to the power \(ns.substring(with: match.range(at: 1))) "
        }
        s = rewrite(pattern: #"_\{([^{}]*)\}"#, in: s) { ns, match in
            " \(ns.substring(with: match.range(at: 1))) "
        }
        s = s.replacingOccurrences(of: "=", with: " equals ")
        s = s.replacingOccurrences(of: "+", with: " plus ")
        s = s.replacingOccurrences(of: "-", with: " minus ")
        s = s.replacingOccurrences(of: "\\left", with: " ")
        s = s.replacingOccurrences(of: "\\right", with: " ")
        s = rewrite(pattern: #"\\[a-zA-Z]+"#, in: s) { ns, match in
            " \(ns.substring(with: match.range).dropFirst()) "
        }
        s = s.replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " ")
        s = s.replacingOccurrences(of: "\\", with: " ")
        return collapsedSpacing(s)
    }

    private static func prettyMath(_ latex: String) -> String {
        var s = latex
        s = rewrite(pattern: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, in: s) { ns, match in
            "(\(prettyMath(ns.substring(with: match.range(at: 1)))))/(\(prettyMath(ns.substring(with: match.range(at: 2)))))"
        }
        s = rewrite(pattern: #"\\sqrt\{([^{}]*)\}"#, in: s) { ns, match in
            "√(\(prettyMath(ns.substring(with: match.range(at: 1)))))"
        }
        s = rewrite(pattern: #"\\(?:text|mathrm|mathbf|mathit)\{([^{}]*)\}"#, in: s) { ns, match in
            ns.substring(with: match.range(at: 1))
        }
        for (command, symbol) in prettySymbols {
            s = s.replacingOccurrences(of: command, with: symbol)
        }
        let supers: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        s = rewrite(pattern: #"\^([0-9])"#, in: s) { ns, match in
            let digit = ns.substring(with: match.range(at: 1))
            return digit.first.flatMap { supers[$0] }.map(String.init) ?? digit
        }
        s = s.replacingOccurrences(of: "\\left", with: "")
        s = s.replacingOccurrences(of: "\\right", with: "")
        s = rewrite(pattern: #"\\[a-zA-Z]+"#, in: s) { ns, match in
            String(ns.substring(with: match.range).dropFirst())
        }
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        s = s.replacingOccurrences(of: "\\", with: "")
        return collapsedSpacing(s)
    }

    private static let spokenSymbols: [(String, String)] = [
        ("\\rightarrow", " arrow "), ("\\leftarrow", " arrow "),
        ("\\infty", " infinity "), ("\\approx", " approximately "),
        ("\\times", " times "), ("\\cdot", " times "),
        ("\\div", " divided by "), ("\\pm", " plus or minus "),
        ("\\neq", " not equal "), ("\\leq", " less than or equal "),
        ("\\geq", " greater than or equal "),
        ("\\alpha", " alpha "), ("\\beta", " beta "), ("\\gamma", " gamma "),
        ("\\delta", " delta "), ("\\theta", " theta "), ("\\lambda", " lambda "),
        ("\\mu", " mu "), ("\\pi", " pi "), ("\\sigma", " sigma "),
        ("\\omega", " omega "), ("\\sum", " sum "), ("\\int", " integral "),
    ]

    private static let prettySymbols: [(String, String)] = [
        ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\infty", "∞"),
        ("\\approx", "≈"), ("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"),
        ("\\pm", "±"), ("\\neq", "≠"), ("\\leq", "≤"), ("\\geq", "≥"),
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
        ("\\theta", "θ"), ("\\lambda", "λ"), ("\\mu", "μ"), ("\\pi", "π"),
        ("\\sigma", "σ"), ("\\omega", "ω"),
    ]

    private static func collapsedSpacing(_ text: String) -> String {
        text.split { $0.isWhitespace }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cloze

    /// Expands `{{c1::text::hint}}` markers.
    /// Question side: active cloze becomes `[...]`, others reveal their text.
    /// Answer side: active cloze reveals its text.
    static func expandClozes(in text: String, reveal: Bool, activeOrdinal: Int) -> String {
        guard text.contains("{{c") else { return text }
        var result = ""
        var scanner = Substring(text)
        while let start = scanner.range(of: "{{c") {
            result += scanner[..<start.lowerBound]
            let rest = scanner[start.upperBound...]
            guard let end = rest.range(of: "}}") else {
                result += rest
                return result
            }
            let inner = rest[rest.startIndex..<end.lowerBound]
            let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            var ordinal = 1
            if parts.count >= 2, let n = Int(parts[0]) {
                ordinal = n
            }
            var contentAndHint = parts.count >= 2 ? String(parts[1]) : ""
            if contentAndHint.hasPrefix(":") { contentAndHint.removeFirst() }
            let contentHint = contentAndHint.split(separator: "::", maxSplits: 1, omittingEmptySubsequences: false)
            let content = contentHint.first.map(String.init) ?? ""
            let hint = contentHint.count > 1 ? String(contentHint[1]) : nil

            let isActive = (ordinal - 1) == activeOrdinal
            if !reveal {
                if isActive {
                    result += hint.map { "[\($0)]" } ?? "[...]"
                } else {
                    result += content
                }
            } else {
                result += content
            }
            scanner = rest[end.upperBound...]
        }
        result += scanner
        return result
    }

    // MARK: - HTML → speech text

    /// Strips HTML into speech-friendly text. Returns (text, mediaFiles).
    /// Text chunk boundaries are marked with U+2028 LINE SEPARATOR (rendered as pauses).
    static func extract(html: String, clozeAnswer: Bool) -> (String, [String]) {
        var text = replace(pattern: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, in: html) { _ in " " }
        var media: [String] = []

        let soundPattern = #"\[sound:([^\]]+)\]"#
        text = replace(pattern: soundPattern, in: text) { match in
            media.append(match)
            return "\u{2028}"
        }

        text = text
            .replacingOccurrences(of: "<br>", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\u{2028}", options: .caseInsensitive)

        text = replace(pattern: #"<[^>]+>"#, in: text) { _ in " " }
        text = decodeEntities(text)

        text = text
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\u{2028}")
        text = text.split(separator: "\u{2028}")
            .map { chunk in
                chunk.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .joined(separator: " ")
            }
            .joined(separator: "\u{2028}")

        if text.contains("{{c") {
            text = expandClozes(in: text, reveal: clozeAnswer, activeOrdinal: -1)
            text = text.replacingOccurrences(of: "[...]", with: "blank")
                .replacingOccurrences(of: "[", with: " ")
                .replacingOccurrences(of: "]", with: " ")
        }

        return (text, media)
    }

    /// Replaces regex matches, invoking `transform` on capture group 1 (or the full match when nil).
    private static func replace(pattern: String, in text: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        return apply(regex, to: text) { ns, match in
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                return transform(ns.substring(with: match.range(at: 1)))
            }
            return transform(ns.substring(with: match.range))
        }
    }

    private static func rewrite(
        pattern: String,
        options: NSRegularExpression.Options = [],
        in text: String,
        transform: (NSString, NSTextCheckingResult) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return apply(regex, to: text, transform: transform)
    }

    private static func apply(
        _ regex: NSRegularExpression,
        to text: String,
        transform: (NSString, NSTextCheckingResult) -> String
    ) -> String {
        let ns = text as NSString
        var result = text
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).reversed()
        for match in matches {
            result = (result as NSString).replacingCharacters(in: match.range, with: transform(ns, match))
        }
        return result
    }

    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&#39;": "'", "&mdash;": "—", "&ndash;": "–",
        "&hellip;": "…", "&rsquo;": "'", "&lsquo;": "'", "&rdquo;": "\"", "&ldquo;": "\"",
    ]

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        result = replace(pattern: #"&#x([0-9a-fA-F]+);"#, in: result) { hex in
            UnicodeScalar(Int(hex, radix: 16) ?? 0).map(String.init) ?? ""
        }
        result = replace(pattern: #"&#(\d+);"#, in: result) { dec in
            UnicodeScalar(Int(dec) ?? 0).map(String.init) ?? ""
        }
        return result
    }
}
