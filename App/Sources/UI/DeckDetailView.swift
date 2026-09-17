import SwiftUI
import Speech
import UIKit

/// Deck detail: one big Study button, today's workload, voice readiness,
/// sub-decks and card management.
struct DeckDetailView: View {
    @Environment(AppServices.self) private var services
    let deckID: Int64

    @State private var deck: Deck?
    @State private var childDecks: [Deck] = []
    @State private var counts: CardRepository.DeckCounts = .init()
    @State private var remaining: StudyQueue.Remaining = .init()
    @State private var voice = VoiceConfig()
    @State private var readiness: OfflineReadiness.Result?
    @State private var sessionActive = false
    @State private var showRename = false
    @State private var shareURL: URL?
    @State private var confirmDelete = false
    @State private var voicePickerTarget: VoicePickerTarget?
    @State private var showVoiceSetup = false

    /// Which voice the picker edits. Most decks follow the Settings default
    /// for their language; a deck with its own override edits that instead,
    /// otherwise the change would have no audible effect here.
    private enum VoicePickerTarget: Int, Identifiable {
        case appDefault, deckOverride
        var id: Int { rawValue }
    }

    private func openVoicePicker() {
        voicePickerTarget = voice.questionVoice == nil ? .appDefault : .deckOverride
    }

    private var deckQuestionVoice: Binding<String?> {
        Binding(
            get: { voice.questionVoice },
            set: { newValue in
                voice.questionVoice = newValue
                try? services.decks.updateVoiceConfig(voice, for: deckID)
            }
        )
    }
    @State private var inventory = VoiceInventory.shared

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
                            showRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            export(deck)
                        } label: {
                            Label("Export as CSV", systemImage: "square.and.arrow.up")
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
            SessionScreen(deckID: deckID)
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
        .sheet(item: $voicePickerTarget) { target in
            // The full picker for this deck's language: choose an installed
            // voice, or follow the guide to download a natural one.
            NavigationStack {
                Group {
                    switch target {
                    case .appDefault:
                        VoicePickerView(initialLocale: voice.questionLocale)
                    case .deckOverride:
                        VoicePickerView(mode: .choose(
                            locale: voice.questionLocale, title: "Question voice",
                            selection: deckQuestionVoice
                        ))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { voicePickerTarget = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $showVoiceSetup) {
            NavigationStack {
                VoiceSetupView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showVoiceSetup = false }
                        }
                    }
            }
        }
        .confirmationDialog("Delete this deck and all its cards?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deck {
                    try? services.decks.delete(deck.id)
                    NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
                }
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
                    sessionActive = true
                } label: {
                    Label("Start Hands-Free Study", systemImage: "waveform")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(remaining.total == 0)
                .accessibilityIdentifier("deck.study")

                voiceStatusRow
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

    /// One line about how this deck will sound. Recognition problems win
    /// over voice quality because they break hands-free entirely. Tapping
    /// always leads somewhere the voice can actually be changed.
    @ViewBuilder
    private var voiceStatusRow: some View {
        if let readiness {
            let quality = VoiceQualityStatus(
                locale: voice.questionLocale, inventory: inventory,
                settings: services.settings, deckVoice: voice.questionVoice
            )
            if !readiness.isReady {
                // A Button, not a NavigationLink: the list would add a second
                // chevron next to the one drawn by `statusLine`.
                Button {
                    showVoiceSetup = true
                } label: {
                    statusLine(ok: false, "Voice needs setup — tap for details")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("deck.voiceSetup")
            } else if !quality.isNatural {
                Button {
                    openVoicePicker()
                } label: {
                    if let better = quality.betterInstalled {
                        statusLine(ok: false, "Robotic voice — \(better.name) is installed, tap to switch")
                    } else {
                        statusLine(ok: false, "Robotic voice — tap to choose or download a natural one")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("deck.voiceGuide")
            } else {
                Button {
                    openVoicePicker()
                } label: {
                    statusLine(ok: true, "Voice ready · \(quality.voice?.name ?? "") · works offline")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("deck.voicePicker")
            }
        }
    }

    private func statusLine(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(ok ? .secondary : .primary)
            Spacer()
            if !ok {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
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
        readiness = await OfflineReadiness.check(voiceConfig: voiceConfig, commandLocale: services.settings.commandLocale)
    }

    private func export(_ deck: Deck) {
        guard let cards = try? services.cards.search(query: "", deckID: deck.id) else { return }
        let csv = ExportService().exportCSV(cards: cards, includeProgress: true)
        let safeName = deck.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).csv")
        do {
            try Data(csv.utf8).write(to: url)
            shareURL = url
        } catch {
            // Export failure is non-fatal; nothing to share.
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
