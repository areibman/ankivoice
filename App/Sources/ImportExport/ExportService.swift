import Foundation

/// CSV/TSV export and full local backup (PRD §28).
public struct ExportService {

    public init() {}

    // MARK: - Delimited text export

    public func exportCSV(
        cards: [StudyCard], delimiter: Character = ",", includeProgress: Bool = false
    ) -> String {
        func quote(_ field: String) -> String {
            if field.contains(delimiter) || field.contains("\"") || field.contains("\n") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }

        var lines: [String] = []
        if includeProgress {
            lines.append(
                ["Front", "Back", "Tags", "State", "Due", "Stability", "Difficulty", "Reps", "Lapses"]
                    .map(quote).joined(separator: String(delimiter))
            )
        } else {
            lines.append("Front\(delimiter)Back\(delimiter)Tags")
        }

        let formatter = ISO8601DateFormatter()
        for card in cards {
            var fields = [card.note.front, card.note.back, card.note.tags.joined(separator: " ")]
            if includeProgress {
                let s = card.card.scheduling
                let stateName: String
                switch s.kind {
                case .new: stateName = "new"
                case .learning: stateName = "learning"
                case .review: stateName = "review"
                case .relearning: stateName = "relearning"
                }
                fields.append(contentsOf: [
                    stateName,
                    formatter.string(from: s.due),
                    s.stability.map { String(format: "%.4f", $0) } ?? "",
                    s.difficulty.map { String(format: "%.4f", $0) } ?? "",
                    String(s.reps),
                    String(s.lapses),
                ])
            }
            lines.append(fields.map(quote).joined(separator: String(delimiter)))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Full local backup

    /// Bundles the SQLite store and all media into a single `.zip` backup.
    public func fullBackup(database: SQLiteDatabase, mediaDirectory: URL?) throws -> URL {
        var writer = ZipWriter()
        try writer.addFile(at: try AppServices.databaseURL(), name: "store.sqlite")

        if let media = mediaDirectory {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: media, includingPropertiesForKeys: nil
            )) ?? []
            for file in files where !file.hasDirectoryPath {
                try writer.addFile(at: file, name: "media/\(file.lastPathComponent)")
            }
        }

        let data = writer.finalize()
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnkiVoice-Backup-\(Self.timestamp()).ankivoicebackup.zip")
        try data.write(to: destination)
        return destination
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
