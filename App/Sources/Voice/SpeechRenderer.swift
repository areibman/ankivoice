import Foundation

/// Renders card content into speakable text (PRD §25).
///
/// Input: card HTML (Anki-style, possibly with cloze markers, `<br>`, `<img>`,
/// `[sound:...]` references).
/// Output: ordered `SpeechSegment`s — synthesized speech with locale, pauses,
/// and pre-recorded media playback.
///
/// The screen renderer and speech renderer are deliberately separate systems:
/// this type knows nothing about visual presentation.
public struct SpeechRenderer: Sendable {

    public init() {}

    // MARK: - Segments

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
        public var compatibility: VoiceCompatibility

        public init(question: [Segment], answer: [Segment], compatibility: VoiceCompatibility) {
            self.question = question
            self.answer = answer
            self.compatibility = compatibility
        }
    }

    // MARK: - Rendering

    /// Renders a study card for speech using per-deck locales.
    public func render(
        _ card: StudyCard, questionLocale: String, answerLocale: String,
        preferRecordedAudio: Bool = false
    ) -> RenderedCard {
        let (questionText, questionMedia, questionCompat) = Self.extract(
            html: Self.templateOutput(for: card, side: .question),
            clozeAnswer: false
        )
        let (answerText, answerMedia, answerCompat) = Self.extract(
            html: Self.templateOutput(for: card, side: .answer),
            clozeAnswer: true
        )

        var question = segments(fromText: questionText, locale: questionLocale)
        var answer = segments(fromText: answerText, locale: answerLocale)
        if preferRecordedAudio {
            // Prepend native-speaker recordings when present (PRD §26).
            question = questionMedia.map { .media(filename: $0) } + question
            answer = answerMedia.map { .media(filename: $0) } + answer
        }

        let compatibility = max(
            max(questionCompat, answerCompat),
            card.noteType.kind == .cloze ? .usable : .excellent
        )
        return RenderedCard(question: question, answer: answer, compatibility: compatibility)
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

    private enum Side {
        case question
        case answer
    }

    /// Minimal Anki-template expansion: {{Field}}, {{FrontSide}}, {{cloze:Field}},
    /// {{hint:Field}}, {{type:Field}} (rendered as a prompt to answer).
    private static func templateOutput(for card: StudyCard, side: Side) -> String {
        let note = card.note
        let noteType = card.noteType

        // Choose the template for this card's ordinal.
        let template = noteType.templates.first { $0.ordinal == card.card.templateOrdinal }
            ?? noteType.templates.first
        var format: String
        if let template {
            format = side == .question ? template.questionFormat : template.answerFormat
        } else if noteType.fieldNames.count >= 2 {
            format = side == .question ? "{{" + noteType.fieldNames[0] + "}}"
                                       : "{{" + noteType.fieldNames[1] + "}}"
        } else {
            format = side == .question ? (note.fields.first ?? "") : (note.fields.last ?? "")
        }

        // {{FrontSide}} echoes the question — the user just heard it seconds
        // ago, so for speech it expands to nothing (voice-first pacing).
        format = format.replacingOccurrences(of: "{{FrontSide}}", with: "")

        // Field substitutions.
        var output = format
        // {{cloze:Text}} → handled during extract for answer side.
        for (index, name) in noteType.fieldNames.enumerated() {
            let value = index < note.fields.count ? note.fields[index] : ""
            output = output.replacingOccurrences(of: "{{\(name)}}", with: value)
            output = output.replacingOccurrences(of: "{{cloze:\(name)}}", with: value)
            output = output.replacingOccurrences(
                of: "{{edit:\(name)}}", with: value
            )
            output = output.replacingOccurrences(
                of: "{{hint:\(name)}}",
                with: value.isEmpty ? "" : "Hint: \(value)"
            )
            output = output.replacingOccurrences(
                of: "{{type:\(name)}}",
                with: ""  // typed recall is not expressible by voice; treat as no-op
            )
        }
        // {{Tags}}, {{Deck}}, {{Subdeck}}
        output = output.replacingOccurrences(
            of: "{{Tags}}", with: note.tags.joined(separator: ", ")
        )
        output = output.replacingOccurrences(of: "{{Deck}}", with: card.deck.fullName)
        output = output.replacingOccurrences(of: "{{Subdeck}}", with: card.deck.name)

        // Cloze: replace the cloze field markers.
        if noteType.kind == .cloze {
            let revealAnswer = side == .answer
            // The template's ordinal selects the active cloze (card N ↔ cN+1).
            output = Self.expandClozes(in: output, reveal: revealAnswer, activeOrdinal: template?.ordinal ?? card.card.templateOrdinal)
        }
        return output
    }

    /// Expands `{{c1::text::hint}}` markers.
    /// Question side: active cloze becomes `[...]`, others reveal their text.
    /// Answer side: active cloze reveals its text.
    static func expandClozes(in text: String, reveal: Bool, activeOrdinal: Int) -> String {
        guard text.contains("{{c") else { return text }
        var result = ""
        var scanner = Substring(text)
        while let start = scanner.range(of: "{{c") {
            result += scanner[..<start.lowerBound]
            // Advance past the "{{c" marker so the inner text starts at the ordinal digits.
            let rest = scanner[start.upperBound...]
            guard let end = rest.range(of: "}}") else {
                result += rest
                return result
            }
            let inner = rest[rest.startIndex..<end.lowerBound]
            // inner: N::content::hint (after the leading "c")
            let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            var ordinal = 1
            if parts.count >= 2, let n = Int(parts[0]) {
                ordinal = n
            }
            // "c1::content::hint" → parts[1] begins with ':'; strip it.
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

    /// Strips HTML into speech-friendly text. Returns (text, mediaFiles, worstCompatibility).
    /// Text chunk boundaries are marked with U+2028 LINE SEPARATOR (rendered as pauses).
    static func extract(html: String, clozeAnswer: Bool) -> (String, [String], VoiceCompatibility) {
        var text = html
        var media: [String] = []
        var compatibility: VoiceCompatibility = .excellent

        // Sounds: [sound:file.mp3]
        let soundPattern = #"\[sound:([^\]]+)\]"#
        text = replace(pattern: soundPattern, in: text) { match in
            media.append(match)
            return "\u{2028}"
        }

        // Images: <img src="...">
        let imgPattern = #"<img[^>]*src=["']?([^"'>\s]+)["']?[^>]*>"#
        text = replace(pattern: imgPattern, in: text) { _ in
            compatibility = max(compatibility, .visualRequired)
            return " "
        }

        // Detect arbitrary script content (unsupported for voice).
        if text.range(of: "<script", options: .caseInsensitive) != nil
            || text.contains("javascript:") {
            compatibility = max(compatibility, .unsupported)
        }

        // Line breaks → chunk separators (pauses).
        text = text
            .replacingOccurrences(of: "<br>", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\u{2028}", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\u{2028}", options: .caseInsensitive)

        // Strip all remaining tags.
        text = replace(pattern: #"<[^>]+>"#, in: text) { _ in " " }

        // HTML entities.
        text = decodeEntities(text)

        // Normalize whitespace within chunks; collapse separators.
        text = text
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\u{2028}")
        text = text.split(separator: "\u{2028}")
            .map { chunk in
                chunk.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .joined(separator: " ")
            }
            .joined(separator: "\u{2028}")

        // Cloze markers that survived (cloze text outside reveal) read as "blank".
        if text.contains("{{c") {
            compatibility = max(compatibility, .usable)
            text = expandClozes(in: text, reveal: clozeAnswer, activeOrdinal: -1)
            text = text.replacingOccurrences(of: "[...]", with: "blank")
                .replacingOccurrences(of: "[", with: " ")
                .replacingOccurrences(of: "]", with: " ")
        }

        return (text, media, compatibility)
    }

    /// Replaces regex matches, invoking `transform` on capture group 1 (or the full match when nil).
    private static func replace(pattern: String, in text: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        var result = text
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            .reversed()
        for match in matches {
            let replacement: String
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                replacement = transform(ns.substring(with: match.range(at: 1)))
            } else {
                replacement = transform(ns.substring(with: match.range))
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
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
        // Numeric entities: &#123; and &#x1F;
        result = replace(pattern: #"&#x([0-9a-fA-F]+);"#, in: result) { hex in
            UnicodeScalar(Int(hex, radix: 16) ?? 0).map(String.init) ?? ""
        }
        result = replace(pattern: #"&#(\d+);"#, in: result) { dec in
            UnicodeScalar(Int(dec) ?? 0).map(String.init) ?? ""
        }
        return result
    }

    // MARK: - Compatibility classification (PRD §24)

    /// Classifies a card's voice compatibility without full rendering.
    public func compatibility(of card: StudyCard) -> VoiceCompatibility {
        _ = self
        let front = card.note.front
        let back = card.note.back
        var worst = VoiceCompatibility.excellent
        for field in [front, back] {
            let (_, _, compat) = Self.extract(html: field, clozeAnswer: false)
            worst = max(worst, compat)
        }
        if card.noteType.kind == .cloze { worst = max(worst, .usable) }
        return worst
    }
}
