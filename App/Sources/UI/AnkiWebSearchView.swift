import SwiftUI

/// Browse AnkiWeb's shared decks, inspect one, and import it directly.
///
/// Search hits the same `/svc/shared` service the website uses, so results
/// and ranking match ankiweb.net. Pasting a deck link or ID jumps straight
/// to that deck.
struct AnkiWebSearchView: View {
    @Environment(AppServices.self) private var services

    @State private var searchText = ""
    @State private var results: [AnkiWebClient.DeckSummary] = []
    @State private var isSearching = false
    @State private var searchError: String?
    /// True when the last error was AnkiWeb's anonymous search cap, so the
    /// error row can offer sign-in as the fix.
    @State private var searchLimited = false
    @State private var hasSearched = false
    @State private var selected: AnkiWebClient.DeckSummary?
    @State private var directItem: AnkiWebSharedItemRef?
    @State private var lastImport: String?
    @State private var showingAccount = false
    @State private var account = AnkiWebAccount()

    private let client = AnkiWebClient()

    var body: some View {
        List {
            if let lastImport {
                Section {
                    Label(lastImport, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let searchError {
                Section {
                    Label(searchError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if searchLimited, !account.isSignedIn {
                        Button {
                            showingAccount = true
                        } label: {
                            Label("Sign in to AnkiWeb", systemImage: "person.crop.circle")
                        }
                        .accessibilityIdentifier("ankiweb.search.signIn")
                    }
                }
            }

            if isSearching {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Searching AnkiWeb…").foregroundStyle(.secondary)
                    }
                }
            } else if results.isEmpty {
                if hasSearched, searchError == nil {
                    ContentUnavailableView.search(text: searchText)
                } else if !hasSearched {
                    Section {
                        ForEach(Self.suggestions, id: \.self) { suggestion in
                            Button {
                                searchText = suggestion
                                Task { await search() }
                            } label: {
                                Label(suggestion, systemImage: "magnifyingglass")
                            }
                        }
                    } header: {
                        Text("Popular searches")
                    } footer: {
                        Text("You can also paste a deck link like ankiweb.net/shared/info/1234567890 into the search field.")
                    }
                }
            } else {
                Section {
                    ForEach(results) { deck in
                        Button {
                            selected = deck
                        } label: {
                            AnkiWebDeckRow(deck: deck)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(results.count) decks · sorted by rating")
                }
            }
        }
        .navigationTitle("AnkiWeb")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search decks or paste a link")
        .onSubmit(of: .search) { Task { await search() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAccount = true
                } label: {
                    Image(systemName: account.isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                }
                .accessibilityLabel(account.isSignedIn ? "AnkiWeb account (signed in)" : "AnkiWeb account")
                .accessibilityIdentifier("ankiweb.account")
            }
        }
        .sheet(item: $selected) { deck in
            NavigationStack {
                AnkiWebDeckDetailView(sharedID: deck.id, title: deck.title, account: account) { summary in
                    lastImport = summary
                }
            }
        }
        .sheet(item: $directItem) { item in
            NavigationStack {
                AnkiWebDeckDetailView(sharedID: item.id, title: nil, account: account) { summary in
                    lastImport = summary
                }
            }
        }
        .sheet(isPresented: $showingAccount) {
            NavigationStack {
                AnkiWebAccountView(account: account)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private static let suggestions = [
        "Japanese", "Spanish vocabulary", "Anatomy", "French verbs", "German", "Korean", "USMLE",
    ]

    private func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        // Deck link or bare ID → open it directly.
        if let id = AnkiWebClient.sharedID(from: query), query.count >= 6 {
            directItem = AnkiWebSharedItemRef(id: id)
            return
        }

        isSearching = true
        searchError = nil
        searchLimited = false
        defer { isSearching = false }
        do {
            let found = try await searchWithSessionRetry(query)
            results = found.sorted { a, b in
                if a.ratingScore != b.ratingScore { return a.ratingScore > b.ratingScore }
                return a.thumbsUp > b.thumbsUp
            }
            hasSearched = true
        } catch {
            results = []
            hasSearched = true
            searchError = error.localizedDescription
            if case AnkiWebClient.ClientError.searchLimitReached = error {
                searchLimited = true
            }
        }
    }

    /// Runs the search; if AnkiWeb answers with its anonymous search cap and
    /// we have stored credentials (cookie expired), sign back in and retry once.
    private func searchWithSessionRetry(_ query: String) async throws -> [AnkiWebClient.DeckSummary] {
        do {
            return try await client.searchDecks(query)
        } catch let error as AnkiWebClient.ClientError {
            guard case .searchLimitReached = error, account.isSignedIn, await account.restoreSession() else {
                throw error
            }
            return try await client.searchDecks(query)
        }
    }
}

/// Wrapper so a pasted shared-item ID can drive `.sheet(item:)`.
struct AnkiWebSharedItemRef: Identifiable, Hashable {
    let id: Int
}

private struct AnkiWebDeckRow: View {
    let deck: AnkiWebClient.DeckSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(deck.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Label(deck.thumbsUp.formatted(), systemImage: "hand.thumbsup")
                if deck.thumbsDown > 0 {
                    Label(deck.thumbsDown.formatted(), systemImage: "hand.thumbsdown")
                }
                Label(deck.notes.formatted(), systemImage: "rectangle.on.rectangle")
                if deck.audio > 0 {
                    Image(systemName: "speaker.wave.2")
                        .accessibilityLabel("Includes audio")
                }
                if deck.images > 0 {
                    Image(systemName: "photo")
                        .accessibilityLabel("Includes images")
                }
                Spacer(minLength: 4)
                if let modified = deck.modified {
                    Text(modified, format: .dateTime.year().month(.abbreviated))
                        .layoutPriority(-1)
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Deck page: description, stats, sample cards, and the import button.
struct AnkiWebDeckDetailView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let sharedID: Int
    let title: String?
    let account: AnkiWebAccount
    let onImported: (String) -> Void

    @State private var info: AnkiWebClient.DeckInfo?
    @State private var loadError: String?
    @State private var phase: Phase = .idle
    @State private var downloadFraction: Double?
    @State private var importTask: Task<Void, Never>?
    @State private var showingSignIn = false

    private let client = AnkiWebClient()

    enum Phase: Equatable {
        case idle
        case downloading
        case importing
        case done(String)
        case failed(String)
        /// AnkiWeb refused the download because of its visitor cap.
        case limited(String)
    }

    var body: some View {
        List {
            if let info {
                header(info)
                let cards = FlashcardPreview.cards(from: info.sampleNotes)
                if !cards.isEmpty {
                    Section {
                        FlashcardPreview(cards: cards)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 10, trailing: 12))
                            .listRowBackground(Color.clear)
                    } header: {
                        Text("Preview cards")
                    } footer: {
                        Text("Swipe for more, tap a card to flip it, and tap the speaker to hear how it sounds with your voices.")
                    }
                }
                actionSection(info)
                if !info.descriptionText.isEmpty {
                    Section("About this deck") {
                        ExpandableText(info.descriptionText)
                    }
                }
                Section {
                    Link(destination: info.pageURL) {
                        Label("View on ankiweb.net", systemImage: "safari")
                    }
                }
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't open this deck",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading deck info…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(info?.title ?? title ?? "Deck")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    importTask?.cancel()
                    dismiss()
                }
            }
        }
        .interactiveDismissDisabled(phase == .downloading || phase == .importing)
        .sheet(isPresented: $showingSignIn) {
            NavigationStack {
                AnkiWebAccountView(account: account) {
                    // Signed in from the cap prompt: pick up where we left off.
                    if let info {
                        importTask = Task { await downloadAndImport(info) }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task { await load() }
    }

    private func header(_ info: AnkiWebClient.DeckInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(info.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 0) {
                    stat(info.notes.formatted(), "cards", "rectangle.on.rectangle")
                    stat(ratingText(info), ratingLabel(info), "hand.thumbsup")
                    stat(ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file), "download", "arrow.down.circle")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if info.audio > 0 {
                            chip("\(info.audio.formatted()) audio clips", "speaker.wave.2")
                        }
                        if info.images > 0 {
                            chip("\(info.images.formatted()) images", "photo")
                        }
                        if let updated = info.lastUpdated {
                            chip("Updated \(updated.formatted(.dateTime.month(.abbreviated).year()))", "clock")
                        }
                        ForEach(info.tags.prefix(8), id: \.self) { tag in
                            chip(tag, "tag")
                        }
                    }
                }
                .scrollClipDisabled()
            }
            .padding(.vertical, 6)
        }
    }

    private func ratingText(_ info: AnkiWebClient.DeckInfo) -> String {
        let total = info.thumbsUp + info.thumbsDown
        guard total > 0 else { return "—" }
        return "\(Int((Double(info.thumbsUp) / Double(total) * 100).rounded()))%"
    }

    private func ratingLabel(_ info: AnkiWebClient.DeckInfo) -> String {
        let total = info.thumbsUp + info.thumbsDown
        guard total > 0 else { return "no ratings" }
        // Compact so it fits a third of the width: "1.6K ratings".
        return "\(total.formatted(.number.notation(.compactName))) ratings"
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
            .lineLimit(1)
    }

    @ViewBuilder
    private func actionSection(_ info: AnkiWebClient.DeckInfo) -> some View {
        Section {
            switch phase {
            case .idle, .failed, .limited:
                Button {
                    importTask = Task { await downloadAndImport(info) }
                } label: {
                    Label("Download & Import", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ankiweb.import")
                if case .failed(let message) = phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if case .limited(let message) = phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                    if !account.isSignedIn {
                        Button {
                            showingSignIn = true
                        } label: {
                            Label("Sign in to AnkiWeb", systemImage: "person.crop.circle")
                        }
                    }
                }
            case .downloading:
                VStack(alignment: .leading, spacing: 8) {
                    if let fraction = downloadFraction {
                        ProgressView(value: fraction) {
                            Text("Downloading… \(Int(fraction * 100))%")
                        }
                    } else {
                        ProgressView { Text("Downloading…") }
                    }
                    Button("Cancel", role: .cancel) {
                        importTask?.cancel()
                        phase = .idle
                    }
                    .font(.callout)
                }
            case .importing:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Importing cards… this can take a moment for large decks.")
                        .foregroundStyle(.secondary)
                }
            case .done(let summary):
                Label(summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done") { dismiss() }
            }
        } footer: {
            if case .idle = phase {
                Text("The deck is added to your library with its cards, tags, media and review history. Notes you already have are skipped.")
            }
        }
    }

    private func load() async {
        do {
            info = try await client.deckInfo(id: sharedID)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Downloads the package, transparently re-authenticating once if AnkiWeb
    /// dropped a signed-in session.
    private func download(_ info: AnkiWebClient.DeckInfo) async throws -> URL {
        let report: @Sendable (Double?) -> Void = { fraction in
            Task { @MainActor in downloadFraction = fraction }
        }
        do {
            return try await client.downloadDeck(info, progress: report)
        } catch let error as AnkiWebClient.ClientError {
            guard case .downloadLimitReached = error, account.isSignedIn, await account.restoreSession() else {
                throw error
            }
            return try await client.downloadDeck(info, progress: report)
        }
    }

    private func downloadAndImport(_ info: AnkiWebClient.DeckInfo) async {
        phase = .downloading
        downloadFraction = nil
        do {
            let file = try await download(info)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            phase = .importing
            let importer = ApkgImporter(decks: services.decks, cards: services.cards, reviews: services.reviews)
            let summary = try await Task.detached(priority: .userInitiated) {
                try importer.importPackage(at: file)
            }.value
            let text = "Imported “\(info.title)”: \(summary.notesImported) notes, \(summary.cardsImported) cards"
                + (summary.mediaImported > 0 ? ", \(summary.mediaImported) media files." : ".")
            phase = .done(text)
            onImported(text)
            NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
        } catch is CancellationError {
            phase = .idle
        } catch let error as AnkiWebClient.ClientError {
            if case .downloadLimitReached = error {
                phase = .limited(error.localizedDescription)
            } else {
                phase = .failed(error.localizedDescription)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Sign in to (or out of) AnkiWeb. Only used to lift the visitor download cap.
struct AnkiWebAccountView: View {
    let account: AnkiWebAccount
    var onSignedIn: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Form {
            if account.isSignedIn {
                Section {
                    Label(account.username ?? "", systemImage: "person.crop.circle.badge.checkmark")
                    Button("Sign Out", role: .destructive) {
                        account.signOut()
                    }
                } footer: {
                    Text("Deck downloads count against your AnkiWeb account instead of the visitor limit. Nothing is uploaded or synced.")
                }
            } else {
                Section {
                    TextField("Email", text: $username)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ankiweb.account.email")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                        .accessibilityIdentifier("ankiweb.account.password")
                } header: {
                    Text("AnkiWeb account")
                } footer: {
                    Text("AnkiWeb limits how many shared decks visitors can download each day; signing in lifts that limit. Your password is kept in the iOS Keychain and only ever sent to ankiweb.net.")
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Sign In").frame(maxWidth: .infinity)
                            if isWorking { ProgressView() }
                        }
                    }
                    .disabled(isWorking || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                Section {
                    Link(destination: URL(string: "https://ankiweb.net/account/signup")!) {
                        Label("Create a free AnkiWeb account", systemImage: "person.badge.plus")
                    }
                    Link(destination: URL(string: "https://ankiweb.net/account/reset-password")!) {
                        Label("Forgot password", systemImage: "key")
                    }
                }
            }
        }
        .navigationTitle("AnkiWeb Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func signIn() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await account.signIn(username: username, password: password)
            password = ""
            dismiss()
            onSignedIn?()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Long text collapsed to a few lines with a "more" toggle.
struct ExpandableText: View {
    let text: String
    var collapsedLines = 5

    @State private var expanded = false

    init(_ text: String, collapsedLines: Int = 5) {
        self.text = text
        self.collapsedLines = collapsedLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .lineLimit(expanded ? nil : collapsedLines)
                .textSelection(.enabled)
            if text.count > 240 || text.filter(\.isNewline).count >= collapsedLines {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.callout.weight(.medium))
            }
        }
        .padding(.vertical, 2)
    }
}

extension Notification.Name {
    /// Posted after an import so deck lists refresh.
    static let ankivoiceLibraryDidChange = Notification.Name("ankivoiceLibraryDidChange")
}
