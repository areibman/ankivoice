import Foundation

/// Anki-style browser search.
///
/// Spaces mean AND. `or` splits alternatives. A leading `-` negates one term.
/// Supported keys: `deck:`, `tag:`, `is:` (new, learn, review, due, suspended,
/// buried), `prop:s`, `prop:d`, `prop:r` with `>`, `<`, `>=`, `<=`, `=`,
/// `rated:days` and `rated:days:ease`, `added:days`, `cid:`, `nid:`, plus
/// plain text over fields and tags.
public enum BrowserQuery {
    public static func match(
        _ cards: [StudyCard], query: String, now: Date = Date(),
        reviewed: [Int64: [ReviewLog]] = [:],
        retrievability: (StudyCard) -> Double = { _ in 1 }
    ) -> [StudyCard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cards }
        let groups = orGroups(tokenize(trimmed))
        return cards.filter { card in
            groups.contains { group in
                group.allSatisfy { term in
                    let hit = matches(card, term: term.body, now: now, reviewed: reviewed, retrievability: retrievability)
                    return term.negated ? !hit : hit
                }
            }
        }
    }

    private struct Term {
        var negated: Bool
        var body: String
    }

    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in query {
            if character == "\"" {
                quoted.toggle()
                continue
            }
            if character == " ", !quoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func orGroups(_ tokens: [String]) -> [[Term]] {
        var groups: [[Term]] = [[]]
        for token in tokens {
            if token.caseInsensitiveCompare("or") == .orderedSame {
                groups.append([])
                continue
            }
            let negated = token.hasPrefix("-") && token.count > 1
            let body = negated ? String(token.dropFirst()) : token
            groups[groups.count - 1].append(Term(negated: negated, body: body))
        }
        return groups.filter { !$0.isEmpty }
    }

    private static func matches(
        _ card: StudyCard, term: String, now: Date,
        reviewed: [Int64: [ReviewLog]], retrievability: (StudyCard) -> Double
    ) -> Bool {
        let lower = term.lowercased()
        if let value = suffix("deck:", lower) {
            let full = card.deck.fullName.lowercased()
            let needle = value.replacingOccurrences(of: "*", with: "")
            if value.contains("*") { return full.contains(needle) }
            return full == needle || full.hasPrefix(needle + "::")
        }
        if let value = suffix("tag:", lower) {
            return card.note.tags.contains { $0.lowercased() == value || $0.lowercased().hasPrefix(value + "::") }
        }
        if let value = suffix("is:", lower) {
            switch value {
            case "new": return card.card.scheduling.kind == .new && !card.card.suspended
            case "learn", "learning": return card.card.scheduling.kind == .learning || card.card.scheduling.kind == .relearning
            case "review": return card.card.scheduling.kind == .review
            case "due": return !card.card.suspended && card.card.scheduling.due <= now && card.card.scheduling.kind != .new
            case "suspended": return card.card.suspended
            case "buried": return card.card.bury != .none
            default: return false
            }
        }
        if let value = suffix("cid:", lower) { return card.id == Int64(value) }
        if let value = suffix("nid:", lower) { return card.note.id == Int64(value) }
        if let value = suffix("added:", lower), let days = Int(value) {
            return card.note.createdAt >= now.addingTimeInterval(-Double(days) * 86_400)
        }
        if let value = suffix("rated:", lower) {
            return rated(card.id, spec: value, now: now, reviewed: reviewed)
        }
        if lower.hasPrefix("prop:") {
            return property(card, spec: String(lower.dropFirst(5)), now: now, retrievability: retrievability)
        }
        let haystack = (card.note.fields.joined(separator: " ") + " " + card.note.tags.joined(separator: " ")).lowercased()
        return haystack.contains(lower)
    }

    private static func suffix(_ prefix: String, _ term: String) -> String? {
        guard term.hasPrefix(prefix) else { return nil }
        return String(term.dropFirst(prefix.count))
    }

    private static func rated(_ cardID: Int64, spec: String, now: Date, reviewed: [Int64: [ReviewLog]]) -> Bool {
        let parts = spec.split(separator: ":")
        guard let days = Int(parts.first ?? ""), days > 0 else { return false }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let logs = reviewed[cardID] ?? []
        let recent = logs.filter { $0.reviewedAt >= cutoff }
        if parts.count >= 2, let ease = Int(parts[1]) {
            return recent.contains { $0.rating.rawValue == ease }
        }
        return !recent.isEmpty
    }

    private static func property(
        _ card: StudyCard, spec: String, now: Date, retrievability: (StudyCard) -> Double
    ) -> Bool {
        let operators = [">=", "<=", "!=", ">", "<", "="]
        guard let op = operators.first(where: { spec.contains($0) }),
              let opRange = spec.range(of: op) else { return false }
        let key = String(spec[..<opRange.lowerBound])
        let raw = String(spec[opRange.upperBound...])
        guard let target = Double(raw) else { return false }
        let value: Double
        switch key {
        case "s": value = card.card.scheduling.stability ?? 0
        case "d": value = card.card.scheduling.difficulty ?? 0
        case "r": value = retrievability(card)
        default: return false
        }
        switch op {
        case ">": return value > target
        case "<": return value < target
        case ">=": return value >= target
        case "<=": return value <= target
        case "!=": return value != target
        default: return value == target
        }
    }
}
