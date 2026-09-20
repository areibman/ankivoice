import SwiftUI

/// Card browser: search, inspect, edit, suspend, delete (PRD §23, §32).
struct CardBrowserView: View {
    @Environment(AppServices.self) private var services
    let deckID: Int64?
    let deckName: String

    @State private var query = ""
    @State private var cards: [StudyCard] = []
    @State private var editing: StudyCard?

    var body: some View {
        List {
            ForEach(cards) { card in
                Button {
                    editing = card
                } label: {
                    CardRow(card: card)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        delete(card)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        try? services.cards.setBuried(
                            card.card.bury == .user ? .none : .user, until: nil, cardID: card.id
                        )
                        Task { await load() }
                    } label: {
                        Label(card.card.bury == .user ? "Unbury" : "Bury", systemImage: "archivebox")
                    }
                    .tint(.indigo)
                    Button {
                        toggleSuspend(card)
                    } label: {
                        Label(
                            card.card.suspended ? "Unsuspend" : "Suspend",
                            systemImage: card.card.suspended ? "play.circle" : "pause.circle"
                        )
                    }
                    .tint(.orange)
                }
            }
        }
        .searchable(text: $query, prompt: "deck: tag: is:due prop:s>21")
        .onChange(of: query) {
            Task { await load() }
        }
        .navigationTitle("Cards")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { card in
            CardEditorView(card: card)
        }
        .task { await load() }
    }

    private func load() async {
        let pool = (try? services.cards.allStudyCards()) ?? []
        let scoped: [StudyCard]
        if let deckID, let root = try? services.decks.deck(id: deckID) {
            let prefix = root.fullName
            scoped = pool.filter {
                $0.deck.fullName == prefix || $0.deck.fullName.hasPrefix(prefix + "::")
            }
        } else {
            scoped = pool
        }
        let logs = (try? services.reviews.allChronological()) ?? []
        let reviewed = Dictionary(grouping: logs, by: \.cardID)
        let scheduler = FSRSScheduler()
        let now = Date()
        cards = Array(BrowserQuery.match(scoped, query: query, now: now, reviewed: reviewed) { card in
            scheduler.retrievability(of: card.card.scheduling.memoryState, now: now)
        }.prefix(2_000))
    }

    private func delete(_ card: StudyCard) {
        try? services.cards.deleteCard(card.id)
        Task { await load() }
    }

    private func toggleSuspend(_ card: StudyCard) {
        try? services.cards.setSuspended(!card.card.suspended, cardID: card.id)
        Task { await load() }
    }
}

private struct CardRow: View {
    let card: StudyCard

    /// What's actually read, not the note's first two fields. Japanese decks
    /// often lead with an index or a notes field, which made the list look
    /// like the tutorial.
    private var spokenLines: (question: String, answer: String) {
        let rendered = SpeechRenderer().render(card, questionLocale: "en-US", answerLocale: "en-US")
        let question = SpeechRenderer.plainText(of: rendered.question)
        let answer = SpeechRenderer.plainText(of: rendered.answer)
        return (
            question.isEmpty ? CardText.plain(card.note.front) : question,
            answer.isEmpty ? CardText.plain(card.note.back) : answer
        )
    }

    var body: some View {
        let spoken = spokenLines
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(spoken.question.prefix(120)))
                    .font(.body)
                    .lineLimit(2)
                if card.card.suspended {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Text(String(spoken.answer.prefix(120)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                stateBadge
                if !card.note.tags.isEmpty {
                    Text(card.note.tags.joined(separator: " "))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.tertiary, in: Capsule())
                }
                Spacer()
                Text("due \(card.card.scheduling.due, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var stateBadge: some View {
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch card.card.scheduling.kind {
        case .new: return "new"
        case .learning: return "learning"
        case .review: return "review"
        case .relearning: return "relearning"
        }
    }

    private var color: Color {
        switch card.card.scheduling.kind {
        case .new: return .blue
        case .learning, .relearning: return .orange
        case .review: return .green
        }
    }
}



/// Edit an existing card's content.
struct CardEditorView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let card: StudyCard

    @State private var front: String
    @State private var back: String
    @State private var tags: String

    init(card: StudyCard) {
        self.card = card
        _front = State(initialValue: card.note.front)
        _back = State(initialValue: card.note.back)
        _tags = State(initialValue: card.note.tags.joined(separator: " "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Front (question)") {
                    TextEditor(text: $front).frame(minHeight: 80)
                }
                Section("Back (answer)") {
                    TextEditor(text: $back).frame(minHeight: 80)
                }
                Section("Tags") {
                    TextField("space separated", text: $tags)
                        .autocorrectionDisabled()
                }
                Section {
                    HStack {
                        Text("Reviews")
                        Spacer()
                        Text("\(card.card.scheduling.reps)").monospacedDigit()
                    }
                    HStack {
                        Text("Lapses")
                        Spacer()
                        Text("\(card.card.scheduling.lapses)").monospacedDigit()
                    }
                    if let s = card.card.scheduling.stability {
                        HStack {
                            Text("Stability")
                            Spacer()
                            Text(String(format: "%.1f days", s)).monospacedDigit()
                        }
                    }
                    if let d = card.card.scheduling.difficulty {
                        HStack {
                            Text("Difficulty")
                            Spacer()
                            Text(String(format: "%.1f", d)).monospacedDigit()
                        }
                    }
                } header: {
                    Text("Scheduling")
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
                        .accessibilityIdentifier("cardeditor.cancel")

                        Button {
                            let tagList = tags.split(separator: " ").map(String.init)
                            try? services.cards.updateNote(
                                id: card.note.id,
                                fields: [front, back],
                                tags: tagList
                            )
                            dismiss()
                        } label: {
                            Text("Save")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("cardeditor.save")
                    }
                }
            }
            .navigationTitle("Edit Card")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
