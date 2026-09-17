import SwiftUI

/// Import decks from Anki desktop over the local network via AnkiConnect.
struct AnkiConnectImportView: View {
    @Environment(AppServices.self) private var services

    @State private var host = ""
    @State private var port = ""
    @State private var apiKey = ""
    @State private var includeMedia = true

    @State private var connecting = false
    @State private var connectionError: String?
    @State private var connectedVersion: Int?
    @State private var decks: [AnkiConnectClient.DeckStats] = []
    @State private var importing: AnkiConnectClient.DeckStats?
    @State private var progress: AnkiConnectImporter.Progress?
    @State private var importTask: Task<Void, Never>?
    @State private var lastResult: String?
    @State private var lastWarnings: [String] = []
    @State private var importError: String?
    @State private var showHelp = false

    var body: some View {
        List {
            connectionSection
            if connectedVersion != nil {
                decksSection
            }
            if importing != nil || lastResult != nil || importError != nil {
                statusSection
            }
            helpSection
        }
        .navigationTitle("Anki on your computer")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(importing != nil)
        .onAppear {
            host = services.settings.ankiConnectHost
            port = String(services.settings.ankiConnectPort)
            apiKey = services.settings.ankiConnectKey
            if !host.isEmpty, connectedVersion == nil {
                Task { await connect() }
            }
        }
        .onDisappear { importTask?.cancel() }
    }

    // MARK: Sections

    private var connectionSection: some View {
        Section {
            HStack {
                Text("Computer")
                    .foregroundStyle(.secondary)
                TextField("192.168.1.20", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { Task { await connect() } }
                    .accessibilityIdentifier("ankiconnect.host")
            }
            HStack {
                Text("Port")
                    .foregroundStyle(.secondary)
                TextField("8765", text: $port)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("API key")
                    .foregroundStyle(.secondary)
                SecureField("Optional", text: $apiKey)
                    .multilineTextAlignment(.trailing)
            }
            Button {
                Task { await connect() }
            } label: {
                HStack {
                    if connecting {
                        ProgressView().padding(.trailing, 4)
                        Text("Connecting…")
                    } else if let version = connectedVersion {
                        Label("Connected · AnkiConnect v\(version)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Spacer()
                    if connectedVersion != nil, !connecting {
                        Text("Refresh").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(connecting || host.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("ankiconnect.connect")
        } header: {
            Text("Connection")
        } footer: {
            if let connectionError {
                Text(connectionError).foregroundStyle(.orange)
            } else {
                Text("Enter the IP address shown in your computer's network settings. Anki must be open, on the same Wi‑Fi, with the AnkiConnect add-on installed.")
            }
        }
    }

    private var decksSection: some View {
        Section {
            if decks.isEmpty {
                Text("No decks found in Anki.").foregroundStyle(.secondary)
            }
            ForEach(decks, id: \.deckID) { deck in
                Button {
                    startImport(deck)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(deck.name.replacingOccurrences(of: "::", with: " › "))
                                .foregroundStyle(.primary)
                            Text("\(deck.totalInDeck.formatted()) cards · \(deck.newCount) new · \(deck.learnCount) learning · \(deck.reviewCount) due")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if importing?.deckID == deck.deckID {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .disabled(importing != nil || deck.totalInDeck == 0)
            }
            Toggle("Include audio and images", isOn: $includeMedia)
                .disabled(importing != nil)
        } header: {
            Text("Decks in Anki")
        } footer: {
            Text("Tap a deck to import it with its subdecks, tags, media and review history. Notes already imported are skipped, so it's safe to run again after studying on your computer.")
        }
    }

    private var statusSection: some View {
        Section {
            if let importing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress?.stage.fraction ?? 0) {
                        Text("Importing “\(importing.name)”")
                    }
                    Text(progress?.stage.title ?? "Starting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel) {
                        importTask?.cancel()
                    }
                    .font(.callout)
                }
            }
            if let lastResult {
                Label(lastResult, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(lastWarnings, id: \.self) { warning in
                Label(warning, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var helpSection: some View {
        Section {
            DisclosureGroup("How to set up AnkiConnect", isExpanded: $showHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "In Anki on your computer, open **Tools ▸ Add-ons ▸ Get Add-ons…**, enter code **2055492159** and restart Anki.")
                    step(2, "Open **Tools ▸ Add-ons**, select AnkiConnect and click **Config**. Change `\"webBindAddress\": \"127.0.0.1\"` to `\"0.0.0.0\"`, save, and restart Anki again.")
                    step(3, "Find your computer's IP address (System Settings ▸ Wi‑Fi ▸ Details on a Mac) and enter it above. Keep Anki open while importing.")
                    Text("Traffic stays on your local network. Windows may ask to allow Anki through the firewall.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func step(_ number: Int, _ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(.init(markdown))
                .font(.callout)
        }
    }

    // MARK: Actions

    private func makeClient() -> AnkiConnectClient? {
        let portValue = Int(port.trimmingCharacters(in: .whitespaces)) ?? AnkiConnectClient.defaultPort
        return AnkiConnectClient(host: host, port: portValue, apiKey: apiKey)
    }

    private func connect() async {
        connecting = true
        connectionError = nil
        defer { connecting = false }
        guard let client = makeClient() else {
            connectionError = AnkiConnectClient.ClientError.invalidEndpoint.localizedDescription
            return
        }
        do {
            let version = try await client.ping()
            let names = try await client.deckNamesAndIDs()
            let stats = try await client.deckStats(names: Array(names.keys))
            decks = stats.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            connectedVersion = version
            services.settings.ankiConnectHost = host.trimmingCharacters(in: .whitespaces)
            services.settings.ankiConnectPort = Int(port) ?? AnkiConnectClient.defaultPort
            services.settings.ankiConnectKey = apiKey
        } catch {
            connectedVersion = nil
            decks = []
            connectionError = error.localizedDescription
        }
    }

    private func startImport(_ deck: AnkiConnectClient.DeckStats) {
        guard importing == nil, let client = makeClient() else { return }
        importing = deck
        progress = nil
        lastResult = nil
        lastWarnings = []
        importError = nil
        let includeMedia = includeMedia
        let importer = AnkiConnectImporter(
            client: client, decks: services.decks, cards: services.cards, reviews: services.reviews
        )
        importTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await importer.importDeck(named: deck.name, includeMedia: includeMedia) { update in
                        Task { @MainActor in progress = update }
                    }
                }.value
                var summary = "Imported “\(deck.name)”: \(result.notesImported) notes, \(result.cardsImported) cards, \(result.reviewsImported) reviews"
                summary += result.mediaImported > 0 ? ", \(result.mediaImported) media files." : "."
                if result.notesSkipped > 0 {
                    summary += " \(result.notesSkipped) already-imported notes skipped."
                }
                lastResult = summary
                lastWarnings = result.warnings
                NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
            } catch is CancellationError {
                importError = "Import cancelled. Cards saved so far are kept; run it again to finish."
            } catch {
                importError = error.localizedDescription
            }
            importing = nil
        }
    }
}
