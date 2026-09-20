import SwiftUI
import UIKit

/// Deck detail: one big Study button, today's workload, sub-decks and card
/// management.
struct DeckDetailView: View {
    @Environment(AppServices.self) private var services
    let deckID: Int64

    @State private var deck: Deck?
    @State private var childDecks: [Deck] = []
    @State private var counts: CardRepository.DeckCounts = .init()
    @State private var remaining: StudyQueue.Remaining = .init()
    @State private var voice = VoiceConfig()
    @State private var sessionActive = false
    @State private var studyDeckID: Int64?
    @State private var gather: StudyQueue.Gather = .scheduled
    @State private var showCustomStudy = false
    @State private var showRename = false
    @State private var shareURL: URL?
    @State private var confirmDelete = false
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        List {
            if let deck {
                heroSection(deck)

                if !childDecks.isEmpty {
                    Section("Sub-decks") {
                        ForEach(childDecks) { child in
                            NavigationLink(value: child) {
                                Label(child.name, systemImage: "square.stack.3d.up.fill")
                            }
                        }
                    }
                }

                Section("Cards") {
                    NavigationLink {
                        CardBrowserView(deckID: deckID, deckName: deck.fullName)
                    } label: {
                        Label("Browse & search cards", systemImage: "list.bullet.rectangle")
                            .badge(counts.total)
                    }
                    NavigationLink {
                        AddCardView(deckID: deckID)
                    } label: {
                        Label("Add card", systemImage: "plus.square")
                    }
                    NavigationLink {
                        DeckSettingsView(deckID: deckID)
                    } label: {
                        Label("Deck settings", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        .navigationTitle(deck?.name ?? "Deck")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let deck {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showCustomStudy = true
                        } label: {
                            Label("Custom study", systemImage: "square.stack.3d.up.badge.a")
                        }
                        Button {
                            showRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            exportAnki(deck, includeScheduling: true)
                        } label: {
                            Label("Export Anki package", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isExporting)
                        .accessibilityIdentifier("deck.export.apkg")
                        Button {
                            exportAnki(deck, includeScheduling: false)
                        } label: {
                            Label("Export Anki package (cards only)", systemImage: "rectangle.stack")
                        }
                        .disabled(isExporting)
                        Button {
                            exportCSV(deck)
                        } label: {
                            Label("Export as CSV", systemImage: "tablecells")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete deck", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationDestination(for: Deck.self) { child in
            DeckDetailView(deckID: child.id)
        }
        .fullScreenCover(isPresented: $sessionActive) {
            SessionScreen(deckID: studyDeckID ?? deckID, gather: gather)
        }
        .sheet(isPresented: $showCustomStudy, onDismiss: { Task { await load() } }) {
            if let deck {
                CustomStudyView(deckName: deck.fullName) { filteredID in
                    studyDeckID = filteredID
                    gather = .scheduled
                    sessionActive = true
                }
            }
        }
        .onChange(of: sessionActive) {
            if !sessionActive { Task { await load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankivoiceSessionDidEnd)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ankivoiceLibraryDidChange)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showRename) {
            if let deck {
                DeckEditView(title: "Rename Deck", initialName: deck.fullName) { newName in
                    try? services.decks.rename(deck.id, to: newName)
                    await load()
                }
            }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
        .confirmationDialog("Delete this deck and all its cards?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deck {
                    try? services.decks.delete(deck.id)
                    NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
                }
            }
        }
        .alert("Couldn't export", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .overlay {
            if isExporting {
                ProgressView("Exporting…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .task { await load() }
    }

    // MARK: Hero

    private func heroSection(_ deck: Deck) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                if deck.parentID != nil {
                    Text(deck.fullName.replacingOccurrences(of: Deck.nameSeparator, with: " › "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if remaining.total > 0 {
                    HStack(spacing: 0) {
                        workloadCell(remaining.newCards, "New", .blue)
                        workloadCell(remaining.learning, "Learning", .orange)
                        workloadCell(remaining.dueReviews, "Due", .green)
                    }
                } else if counts.total == 0 {
                    Label("This deck has no cards yet. Add one below.", systemImage: "tray")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("All caught up — nothing due today.", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }

                Button {
                    studyDeckID = deckID
                    gather = remaining.total > 0 ? .scheduled : .more
                    sessionActive = true
                } label: {
                    Label(remaining.total > 0 ? "Start Hands-Free Study" : "Study more", systemImage: "waveform")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(counts.total == 0 || counts.total == counts.suspended)
                .accessibilityIdentifier("deck.study")
            }
            .padding(.vertical, 6)
        } footer: {
            Text("\(counts.total) cards" + (counts.suspended > 0 ? " · \(counts.suspended) suspended" : "")
                 + " · reads \(languageName(voice.questionLocale))"
                 + (voice.answerLocale != voice.questionLocale ? " → \(languageName(voice.answerLocale))" : ""))
        }
    }

    private func workloadCell(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(value > 0 ? color : .secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func languageName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        let language = locale.language.languageCode?.identifier ?? code
        return Locale.current.localizedString(forLanguageCode: language) ?? code
    }

    // MARK: Data

    private func load() async {
        deck = try? services.decks.deck(id: deckID)
        counts = (try? services.cards.counts(forDeck: deckID)) ?? .init()
        let (study, voiceConfig, _) = (try? services.decks.config(for: deckID)) ?? (StudyConfig(), VoiceConfig(), nil)
        voice = voiceConfig
        remaining = (try? services.queue.remaining(forDeck: deckID, config: study)) ?? .init()
        childDecks = (try? services.decks.all().filter { $0.parentID == deckID }) ?? []
    }

    private func exportCSV(_ deck: Deck) {
        do {
            let ids = try services.cards.descendantDeckIDs(including: deck.id)
            let cards = try services.cards.studyCards(inDeckIDs: ids)
            let csv = ExportService().exportCSV(cards: cards, includeProgress: true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(ApkgExporter.safeFilename(deck.name)).csv")
            try Data(csv.utf8).write(to: url)
            shareURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportAnki(_ deck: Deck, includeScheduling: Bool) {
        isExporting = true
        exportError = nil
        let decks = services.decks
        let cards = services.cards
        let reviews = services.reviews
        let deckID = deck.id
        Task {
            defer { isExporting = false }
            do {
                let media = try AppServices.mediaDirectory()
                let result = try await Task.detached(priority: .userInitiated) {
                    try ApkgExporter(decks: decks, cards: cards, reviews: reviews).exportDeck(
                        id: deckID,
                        options: ApkgExporter.Options(includeScheduling: includeScheduling, includeMedia: true),
                        mediaDirectory: media
                    )
                }.value
                shareURL = result.url
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// UIActivityViewController wrapper.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Add-card sheet.
struct AddCardView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let deckID: Int64

    @State private var front = ""
    @State private var back = ""
    @State private var tags = ""

    var body: some View {
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
                HStack(spacing: 12) {
                    Button(role: .cancel) {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("addcard.cancel")

                    Button {
                        let tagList = tags.split(separator: " ").map(String.init)
                        _ = try? services.cards.createNote(
                            fields: [front, back], tags: tagList, deckID: deckID
                        )
                        NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
                        dismiss()
                    } label: {
                        Text("Add card")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(front.trimmingCharacters(in: .whitespaces).isEmpty
                              || back.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("addcard.save")
                }
            }
        }
        .navigationTitle("Add Card")
        .navigationBarTitleDisplayMode(.inline)
    }
}
