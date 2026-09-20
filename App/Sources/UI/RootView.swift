import SwiftUI

struct RootView: View {
    @Environment(AppServices.self) private var services
    @State private var selectedTab = 0
    /// UI tests can force onboarding on a device that already completed it.
    @State private var forceOnboarding = ProcessInfo.processInfo.arguments.contains("-uiTestForceOnboarding")
    private let skipOnboarding = ProcessInfo.processInfo.arguments.contains("-uiTestSkipOnboarding")
    @State private var openedFileMessage: String?
    @State private var openedFileError: String?

    private var showOnboarding: Binding<Bool> {
        Binding(
            get: { forceOnboarding || (!services.settings.onboardingComplete && !skipOnboarding) },
            set: { shown in if !shown { completeOnboarding() } }
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DeckListView()
                .tabItem { Label("Decks", systemImage: "square.stack.3d.up") }
                .tag(0)
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .fullScreenCover(isPresented: showOnboarding) {
            OnboardingView { completeOnboarding() }
        }
        .onOpenURL { url in
            Task { await importOpenedFile(url) }
        }
        .alert("Imported", isPresented: Binding(
            get: { openedFileMessage != nil },
            set: { if !$0 { openedFileMessage = nil } }
        )) {
            Button("OK", role: .cancel) { openedFileMessage = nil }
        } message: {
            Text(openedFileMessage ?? "")
        }
        .alert("Couldn't import", isPresented: Binding(
            get: { openedFileError != nil },
            set: { if !$0 { openedFileError = nil } }
        )) {
            Button("OK", role: .cancel) { openedFileError = nil }
        } message: {
            Text(openedFileError ?? "")
        }
    }

    private func completeOnboarding() {
        services.settings.onboardingComplete = true
        forceOnboarding = false
    }

    /// Files / AirDrop / “Open in AnkiVoice” for `.apkg`, `.colpkg`, CSV and TSV.
    private func importOpenedFile(_ url: URL) async {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let decks = services.decks
        let cards = services.cards
        let reviews = services.reviews
        let ext = url.pathExtension.lowercased()
        guard ["apkg", "colpkg", "zip", "csv", "tsv", "txt"].contains(ext) else { return }
        let isPackage = ext.hasPrefix("apkg") || ext == "colpkg" || ext == "zip"
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                if isPackage {
                    let result = try ApkgImporter(decks: decks, cards: cards, reviews: reviews)
                        .importPackage(at: url)
                    return "Imported \(result.notesImported) notes, \(result.cardsImported) cards, \(result.reviewsImported) reviews."
                } else {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let name = url.deletingPathExtension().lastPathComponent
                    let result = try DelimitedTextImporter(cards: cards, decks: decks)
                        .importText(text, intoDeck: name, hasHeader: false)
                    return "Imported \(result.notesImported) cards into “\(name)”."
                }
            }.value
            openedFileMessage = summary
            NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
        } catch {
            openedFileError = error.localizedDescription
        }
    }
}

#Preview {
    let db = try! SQLiteDatabase.inMemory()
    try! Schema.migrate(db: db)
    return RootView().environment(AppServices(database: db))
}
