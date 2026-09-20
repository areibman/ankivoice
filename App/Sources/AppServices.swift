import Foundation

/// Dependency container for the application.
/// Wires the database, repositories, scheduler and settings together.
@MainActor
@Observable
final class AppServices {
    let database: SQLiteDatabase
    let decks: DeckRepository
    let cards: CardRepository
    let reviews: ReviewRepository
    let stats: StatsStore
    let settings: SettingsStore
    let queue: StudyQueue

    init(database: SQLiteDatabase) {
        self.database = database
        self.decks = DeckRepository(db: database)
        self.cards = CardRepository(db: database)
        self.reviews = ReviewRepository(db: database)
        self.stats = StatsStore(db: database)
        self.settings = SettingsStore.defaults
        self.queue = StudyQueue(cards: cards, reviews: reviews)
    }

    /// Production container backed by the on-disk database in Application Support.
    static var live: AppServices {
        do {
            let url = try Self.databaseURL()
            let db = try SQLiteDatabase.open(url: url)
            try Schema.migrate(db: db)
            return AppServices(database: db)
        } catch {
            // A corrupt store is unrecoverable for a local-first app; fail loudly
            // rather than silently running without persistence.
            fatalError("Failed to open database: \(error)")
        }
    }

    nonisolated static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let appDir = dir.appendingPathComponent("AnkiVoice", isDirectory: true)
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("store.sqlite")
    }

    /// Media (audio recordings / images) imported alongside cards.
    nonisolated static func mediaDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let media = dir.appendingPathComponent("AnkiVoice/media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        return media
    }
}


/// Asks a touch-only session to try voice mode again — typically after the
/// user came back from enabling Dictation or a permission in Settings. The
/// session screen restarts with a fresh engine, which re-runs every check.
extension AppServices {
    func retryVoiceSetup() {
        NotificationCenter.default.post(name: .ankivoiceVoiceSetupRetried, object: nil)
    }
}

extension Notification.Name {
    static let ankivoiceVoiceSetupRetried = Notification.Name("ankivoiceVoiceSetupRetried")
}
