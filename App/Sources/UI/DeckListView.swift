import SwiftUI

/// Deck library: what's due today, at a glance, with one tap into studying.
struct DeckListView: View {
    @Environment(AppServices.self) private var services
    @State private var decks: [DeckRowModel] = []
    @State private var loaded = false
    @State private var showAddDeck = false
    @State private var loadFailed: String?

    struct DeckRowModel: Identifiable {
        let id: Int64
        let deck: Deck
        var counts: CardRepository.DeckCounts
        var remaining: StudyQueue.Remaining
        var lastStudied: Date?
        var reviewedToday: Int
    }

    var body: some View {
        NavigationStack {
            Group {
                if loaded && decks.isEmpty {
                    emptyState
                } else {
                    List {
                        if totalDue > 0 {
                            Section {
                                HStack(spacing: 12) {
                                    Image(systemName: "waveform.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(totalDue) cards to study today")
                                            .font(.headline)
                                        Text("Open a deck and start a hands-free session.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        Section {
                            ForEach(decks) { row in
                                NavigationLink(value: row.deck) {
                                    DeckRow(row: row)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        delete(row)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            if totalDue == 0, !decks.isEmpty {
                                Text("All caught up for today")
                            }
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Decks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddDeck = true
                    } label: {
                        Label("Add deck", systemImage: "plus")
                    }
                    .accessibilityIdentifier("decks.add")
                }
            }
            .navigationDestination(for: Deck.self) { deck in
                DeckDetailView(deckID: deck.id)
            }
            .sheet(isPresented: $showAddDeck, onDismiss: { Task { await load() } }) {
                AddDeckView()
            }
            .alert("Something went wrong", isPresented: .init(
                get: { loadFailed != nil }, set: { if !$0 { loadFailed = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loadFailed ?? "")
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .ankivoiceSessionDidEnd)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankivoiceLibraryDidChange)) { _ in
            Task { await load() }
        }
    }

    private var totalDue: Int {
        decks.reduce(0) { $0 + $1.remaining.total }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No decks yet", systemImage: "square.stack.3d.up")
        } description: {
            Text("Browse thousands of shared decks, import your own, or start from scratch.")
        } actions: {
            Button {
                showAddDeck = true
            } label: {
                Label("Add a deck", systemImage: "plus")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func load() async {
        do {
            try SampleContent.seedIfNeeded(decks: services.decks, cards: services.cards)
            var rows: [DeckRowModel] = []
            // Only top-level decks are listed; child decks show inside the parent.
            let all = try services.decks.all()
            for deck in all where deck.parentID == nil {
                let counts = try services.cards.counts(forDeck: deck.id)
                let (study, _, lastStudied) = try services.decks.config(for: deck.id)
                let remaining = (try? services.queue.remaining(forDeck: deck.id, config: study)) ?? .init()
                let reviewedToday = try services.reviews.reviewCountToday(deckID: deck.id)
                rows.append(
                    DeckRowModel(
                        id: deck.id, deck: deck, counts: counts, remaining: remaining,
                        lastStudied: lastStudied, reviewedToday: reviewedToday
                    )
                )
            }
            decks = rows
            loaded = true
        } catch {
            loadFailed = error.localizedDescription
            loaded = true
        }
    }

    private func delete(_ row: DeckRowModel) {
        try? services.decks.delete(row.id)
        Task { await load() }
    }
}

private struct DeckRow: View {
    let row: DeckListView.DeckRowModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(row.deck.fullName.replacingOccurrences(of: Deck.nameSeparator, with: " › "))
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    countChip(row.remaining.newCards, "new", .blue)
                    countChip(row.remaining.learning, "learning", .orange)
                    countChip(row.remaining.dueReviews, "due", .green)
                    if row.remaining.total == 0 {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if row.remaining.total > 0 {
                Text("\(row.remaining.total)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor, in: Capsule())
                    .accessibilityLabel("\(row.remaining.total) to study")
            } else if row.counts.total > 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Done for today")
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if row.counts.total == 0 { return "Empty deck" }
        if row.counts.total == row.counts.suspended { return "All cards suspended" }
        var parts = ["\(row.counts.total) cards"]
        if row.reviewedToday > 0 {
            parts.append("\(row.reviewedToday) reviewed today")
        } else if let last = row.lastStudied {
            parts.append("studied \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func countChip(_ count: Int, _ label: String, _ color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Text("\(count)").bold().monospacedDigit()
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(color)
        }
    }
}

/// Create/rename deck sheet. `::` builds a hierarchy.
struct DeckEditView: View {
    let title: String
    let initialName: String
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String, initialName: String, onSave: @escaping (String) async -> Void) {
        self.title = title
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Deck name", text: $name)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text("Use :: to nest decks, e.g. Languages::Japanese::Vocabulary")
                }
                Section {
                    HStack(spacing: 12) {
                        Button(role: .cancel) {
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)

                        Button(action: save) {
                            Text("Save")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            await onSave(trimmed)
            dismiss()
        }
    }
}
