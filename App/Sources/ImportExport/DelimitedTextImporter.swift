import Foundation

/// CSV/TSV import (PRD §27).
///
/// Auto-detects the delimiter, honors RFC 4180 quoting, and maps
/// column 1 → front, column 2 → back, column 3 → tags (space separated).
public struct DelimitedTextImporter: Sendable {

    public struct Result: Sendable, Equatable {
        public var deckID: Int64
        public var notesImported: Int
        public var notesSkipped: Int
    }

    public enum Format: String, Sendable {
        case comma
        case tab
        case semicolon

        var delimiter: Character {
            switch self {
            case .comma: return ","
            case .tab: return "\t"
            case .semicolon: return ";"
            }
        }
    }

    private let cards: CardRepository
    private let decks: DeckRepository

    public init(cards: CardRepository, decks: DeckRepository) {
        self.cards = cards
        self.decks = decks
    }

    /// Detects the delimiter from the first non-empty line.
    public static func detectFormat(_ text: String) -> Format {
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let tabCount = firstLine.filter { $0 == "\t" }.count
        if tabCount > 0 { return .tab }
        let commaCount = firstLine.filter { $0 == "," }.count
        if commaCount > 0 { return .comma }
        let semicolonCount = firstLine.filter { $0 == ";" }.count
        if semicolonCount > 0 { return .semicolon }
        return .comma
    }

    /// Parses delimited text into rows of fields.
    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending {
                pending = nil
                return p
            }
            return iterator.next()
        }

        while let c = nextChar() {
            if inQuotes {
                if c == "\"" {
                    if let lookahead = nextChar() {
                        if lookahead == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = lookahead
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                if c == "\"" && field.isEmpty {
                    inQuotes = true
                } else if c == delimiter {
                    currentRow.append(field)
                    field = ""
                } else if c == "\n" || c == "\r" {
                    if c == "\r" {
                        // Treat CRLF as one newline.
                        if let lookahead = nextChar(), lookahead != "\n" {
                            pending = lookahead
                        }
                    }
                    currentRow.append(field)
                    field = ""
                    if !(currentRow.count == 1 && currentRow[0].isEmpty) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                } else {
                    field.append(c)
                }
            }
        }
        if !field.isEmpty || !currentRow.isEmpty {
            currentRow.append(field)
            if !(currentRow.count == 1 && currentRow[0].isEmpty) {
                rows.append(currentRow)
            }
        }
        return rows
    }

    /// Imports delimited text into a deck. `header` skips the first row.
    public func importText(
        _ text: String,
        intoDeck deckName: String,
        format: Format? = nil,
        hasHeader: Bool = false
    ) throws -> Result {
        let detected = format ?? Self.detectFormat(text)
        var rows = Self.parse(text, delimiter: detected.delimiter)

        if hasHeader, !rows.isEmpty {
            rows.removeFirst()
        }

        let deck = try decks.create(fullName: deckName)
        var imported = 0
        var skipped = 0

        for row in rows {
            let fields = row.map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                skipped += 1
                continue
            }
            let tags = fields.count > 2
                ? fields[2].split(separator: " ").map(String.init).filter { !$0.isEmpty }
                : []
            _ = try cards.createNote(
                fields: [fields[0], fields[1]], tags: tags, deckID: deck.id
            )
            imported += 1
        }

        return Result(deckID: deck.id, notesImported: imported, notesSkipped: skipped)
    }
}
