import Foundation

/// Deterministic mapping from recognized speech to voice commands (PRD §12, §13).
///
/// No LLM: exact canonical commands plus a small alias table, gated by session state.
/// Matching is deliberately aggressive (constrained vocabulary) but conservative
/// about false positives: a transcript only maps to a command when the command
/// word appears as a whole word in the *current* listening window.
public struct CommandRecognizer: Sendable {

    public init() {}

    // MARK: - Commands

    public enum Command: String, Sendable, CaseIterable, Identifiable {
        case again
        case hard
        case good
        case easy
        case repeatQuestion = "repeat question"
        case repeatAnswer = "repeat answer"
        case repeatContent = "repeat"
        case reveal
        case pause
        case resume
        case undo
        case skip
        case stop

        public var id: String { rawValue }
    }

    /// Commands valid in each listening state.
    public enum ListeningPhase: Sendable, Equatable {
        /// Listening for the user's answer (or pre-answer commands).
        case awaitingAnswer
        /// Listening for a rating.
        case awaitingRating
        /// Paused; listening only for resume/stop.
        case paused
    }

    public struct Match: Sendable, Equatable {
        public var command: Command
        /// Range of the matched command in the source transcript.
        public var range: Range<String.Index>
    }

    // MARK: - Alias table (PRD §12)

    private static let aliases: [String: Command] = {
        var table: [String: Command] = [:]
        for command in Command.allCases {
            table[command.rawValue] = command
        }
        // Limited aliases; canonical commands remain strongly preferred.
        table["wrong"] = .again
        table["forgot"] = .again
        table["forgotten"] = .again
        table["didn't remember"] = .again
        table["difficult"] = .hard
table["submit"] = .reveal
table["show answer"] = .reveal
table["show me"] = .reveal
        table["next"] = .reveal
        table["skip it"] = .skip
        table["go back"] = .undo
        table["say it again"] = .repeatContent
        table["come again"] = .repeatContent
        table["what"] = .repeatContent
        table["pardon"] = .repeatContent
        return table
    }()

    // MARK: - Recognition

    /// Finds the first command in `transcript` valid for `phase`.
    ///
    /// Longer phrases are matched first ("repeat question" before "repeat").
    /// Returns nil when nothing in the transcript is a valid command for the phase.
    public func recognize(transcript: String, phase: ListeningPhase) -> Match? {
        let normalized = Self.normalize(transcript)
        guard !normalized.isEmpty else { return nil }
        let words = normalized.split(separator: " ").map(String.init)

        // Scan word windows longest-first at each position.
        let maxWindow = 3
        for i in 0..<words.count {
            var window = maxWindow
            while window >= 1 {
                let upper = i + window
                guard upper <= words.count else { window -= 1; continue }
                let phrase = words[i..<upper].joined(separator: " ")
                if let command = Self.aliases[phrase], Self.isValid(command, in: phase),
                   let range = normalized.range(of: phrase) {
                    return Match(command: command, range: range)
                }
                window -= 1
            }
        }
        return nil
    }

    static func isValid(_ command: Command, in phase: ListeningPhase) -> Bool {
        switch phase {
        case .awaitingAnswer:
            // Ratings are NOT accepted before the answer is revealed (PRD §13).
            switch command {
            case .repeatContent, .repeatQuestion, .repeatAnswer, .reveal,
                 .pause, .undo, .skip, .stop:
                return true
            case .again, .hard, .good, .easy, .resume:
                return false
            }
        case .awaitingRating:
            switch command {
            case .again, .hard, .good, .easy,
                 .repeatContent, .repeatQuestion, .repeatAnswer, .pause, .undo, .stop:
                return true
            case .reveal, .resume, .skip:
                return false
            }
        case .paused:
            return command == .resume || command == .stop || command == .repeatContent
        }
    }

    // MARK: - Normalization

    /// Lowercase, strip punctuation, collapse whitespace, and spell out digits
    /// (recognizers often emit "4" for "four").
    static func normalize(_ transcript: String) -> String {
        var text = transcript.lowercased()
        // Curly quotes and dashes separate words for matching purposes.
        for symbol in ["’", "'", "—", "–", ",", ".", "!", "?", ";", ":"] {
            text = text.replacingOccurrences(of: symbol, with: " ")
        }
        // Digit spellings for one..nine (four → easy contexts avoided; only used verbatim).
        let digits = ["1": "one", "2": "two", "3": "three", "4": "four", "5": "five",
                      "6": "six", "7": "seven", "8": "eight", "9": "nine"]
        text = text.split(separator: " ").map { word -> String in
            digits[String(word)] ?? String(word)
        }.joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
