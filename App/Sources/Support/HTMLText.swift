import Foundation

/// Reduces Anki-flavoured HTML to plain text for on-screen display.
///
/// Block-level closers become line breaks, tags and `[sound:…]` references
/// are dropped, common entities are decoded. Speech rendering has its own,
/// pause-aware path in `SpeechRenderer`.
enum HTMLText {
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        for br in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>", "</h1>", "</h2>", "</h3>"] {
            text = text.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[sound:[^\]]*\]"#, with: "", options: .regularExpression)
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let entities: [String: String] = [
        "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
    ]
}

/// Shared-deck "read this first" notes. Authors often put a long tutorial as
/// the first note, and AnkiWeb's samples lead with it — so a Japanese deck
/// sounds like it's reading the instructions instead of the cards.
enum DeckTutorial {
    /// True when the note is a deck readme rather than a study card.
    ///
    /// A long instructions field is not enough: real cards keep a short
    /// prompt (a word, a sentence) next to a Notes essay. Only notes whose
    /// fields are *all* the essay count.
    static func isReadme(fieldTexts: [String]) -> Bool {
        let plains = fieldTexts
            .map { HTMLText.plain($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let longest = plains.max(by: { $0.count < $1.count }), longest.count >= 350 else { return false }
        let lower = longest.lowercased()
        let hits = markers.filter { lower.contains($0) }.count
        guard hits >= 2 else { return false }
        let others = plains.filter { $0 != longest }
        let hasStudyPrompt = others.contains { text in
            text.count <= 80 && !markers.contains { text.lowercased().contains($0) }
        }
        return !hasStudyPrompt
    }

    /// The one-note `collection.anki2` stub older Anki packages ship next to
    /// the real collection ("please update Anki").
    static func isAnkiUpgradeNotice(fieldTexts: [String]) -> Bool {
        let text = fieldTexts
            .map { HTMLText.plain($0) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !text.isEmpty, text.count < 500 else { return false }
        return text.contains("newer version of anki")
            || text.contains("please update to the latest anki")
            || text.contains("requires a newer version of anki")
    }

    private static let markers = [
        "this deck", "how to use", "how to study", "please read", "before you",
        "instructions", "readme", "read this", "ankiweb", "subdeck",
        "download the", "thank you for downloading", "getting started",
    ]
}
