import SwiftUI

/// Global settings: voices, listening behaviour, study preferences, backup
/// and diagnostics.
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var inventory = VoiceInventory.shared
    @State private var backupURL: URL?
    @State private var backupError: String?
    @State private var isExporting = false
    @State private var reportCopied = false
    @State private var optimizing = false
    @State private var optimizeMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        VoicePickerView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: voiceStatus.isNatural ? "checkmark.seal.fill" : "waveform.badge.exclamationmark")
                                .foregroundStyle(voiceStatus.isNatural ? .green : .orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Voices & speed")
                                Text(voiceSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.voices")
                    Picker("Command language", selection: binding(\.commandLocale)) {
                        ForEach(commandLocales, id: \.self) { locale in
                            Text(localeName(locale)).tag(locale)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Pick the voice that reads cards in each language, or leave it on Automatic for the most natural iOS voice installed. Supertonic 3 is an on-device alternative you opt into. Commands like “good” and “repeat” are recognized in the command language.")
                }

                Section {
                    Picker("Response speed", selection: binding(\.endpointProfile)) {
                        ForEach(SettingsStore.EndpointProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    Stepper(value: bindingInt(\.answerTimeoutSeconds), in: 0...300, step: 15) {
                        LabeledContent("Hint after silence") {
                            Text(services.settings.answerTimeoutSeconds == 0 ? "Never" : "\(services.settings.answerTimeoutSeconds)s")
                                .monospacedDigit()
                        }
                    }
                    Toggle("Wait for a spoken answer", isOn: binding(\.requireSpokenAnswer))
                    Toggle("Allow “reveal” command", isOn: binding(\.allowRevealCommand))
                } header: {
                    Text("Listening")
                } footer: {
                    Text("Response speed sets how long a pause ends your answer. Turn off “Wait for a spoken answer” to have the answer read after a short pause even if you stay silent.")
                }

                Section {
                    Toggle("Two-button ratings", isOn: binding(\.simplifiedRatings))
                    Toggle("Auto-start next card", isOn: binding(\.autoStartNextCard))
                    Toggle("Confirm rating out loud", isOn: binding(\.announceRatingConfirmation))
                    Toggle("Announce next interval", isOn: binding(\.announceNextInterval))
                    Toggle("Pause when headphones disconnect", isOn: binding(\.pauseWhenHeadphonesDisconnect))
                } header: {
                    Text("Study")
                } footer: {
                    Text("Two-button ratings accept only “again” and “good” — simpler to say while walking.")
                }

                Section {
                    NavigationLink {
                        VoiceSetupView()
                    } label: {
                        Label("Voice setup check", systemImage: "waveform.badge.magnifyingglass")
                    }
                    Button {
                        exportAnkiCollection()
                    } label: {
                        Label("Export collection for Anki", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isExporting)
                    .accessibilityIdentifier("settings.export.colpkg")
                    Button {
                        createBackup()
                    } label: {
                        Label("Create full backup", systemImage: "externaldrive.badge.timemachine")
                    }
                    .disabled(isExporting)
                    if let backupError {
                        Text(backupError).font(.caption).foregroundStyle(.red)
                    }
                    Button {
                        optimizeCollection()
                    } label: {
                        Label(optimizing ? "Optimizing FSRS…" : "Optimize FSRS for all decks", systemImage: "function")
                    }
                    .disabled(optimizing)
                    if let optimizeMessage {
                        Text(optimizeMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        UIPasteboard.general.string = DiagnosticReport.generate(commandLocale: services.settings.commandLocale)
                        reportCopied = true
                    } label: {
                        Label(reportCopied ? "Diagnostic report copied" : "Copy diagnostic report",
                              systemImage: reportCopied ? "checkmark.circle" : "doc.on.doc")
                    }
                } header: {
                    Text("Data & troubleshooting")
                } footer: {
                    Text("Anki packages (.apkg / .colpkg) include cards, media and review history so you can open them in Anki. The full backup is AnkiVoice-only. The diagnostic report lists speech, voice and crash information — no card content.\n\nAnkiVoice \(Self.versionString) · FSRS-6 scheduling, on device. Speech is recognized on your iPhone; spoken answers are never stored or sent anywhere.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { inventory.refresh() }
            .sheet(item: $backupURL) { url in
                ShareSheet(items: [url])
            }
            .overlay {
                if isExporting {
                    ProgressView("Exporting…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func optimizeCollection() {
        optimizing = true
        optimizeMessage = nil
        let reviews = services.reviews
        let settings = services.settings
        Task {
            defer { optimizing = false }
            do {
                let logs = try reviews.allChronological()
                let report = try await Task.detached(priority: .userInitiated) {
                    try FSRSOptimizer().optimize(logs: logs)
                }.value
                settings.fsrsParameters = report.parameters
                optimizeMessage = String(
                    format: "Fit %d reviews. Loss %.3f → %.3f. Decks without their own weights use this.",
                    report.reviewCount, report.lossBefore, report.lossAfter
                )
            } catch let failure as FSRSOptimizer.Failure {
                if case .notEnoughReviews(let have, let need) = failure {
                    optimizeMessage = "Need \(need) reviews to optimize. This collection has \(have)."
                }
            } catch {
                optimizeMessage = error.localizedDescription
            }
        }
    }

    private func exportAnkiCollection() {
        isExporting = true
        backupError = nil
        let decks = services.decks
        let cards = services.cards
        let reviews = services.reviews
        Task {
            defer { isExporting = false }
            do {
                let media = try AppServices.mediaDirectory()
                let result = try await Task.detached(priority: .userInitiated) {
                    try ApkgExporter(decks: decks, cards: cards, reviews: reviews).exportCollection(
                        mediaDirectory: media
                    )
                }.value
                backupURL = result.url
            } catch {
                backupError = error.localizedDescription
            }
        }
    }

    private func createBackup() {
        do {
            let media = try AppServices.mediaDirectory()
            backupURL = try ExportService().fullBackup(database: services.database, mediaDirectory: media)
            backupError = nil
        } catch {
            backupError = error.localizedDescription
        }
    }

    private var voiceStatus: VoiceQualityStatus {
        VoiceQualityStatus(locale: services.settings.commandLocale, inventory: inventory, settings: services.settings)
    }

    private var voiceSummary: String {
        let status = voiceStatus
        guard let voice = status.voice else { return "No voice installed" }
        if voice.kind == .supertonic3 {
            return "\(voice.name) · Supertonic 3"
        }
        if let better = status.betterInstalled {
            return "\(voice.name) · built-in — \(better.name) is installed"
        }
        switch voice.quality {
        case .premium: return "\(voice.name) · Premium"
        case .enhanced: return "\(voice.name) · Enhanced"
        case .compact: return "\(voice.name) · built-in — get a natural voice"
        }
    }

    private let commandLocales = ["en-US", "en-GB", "en-AU", "de-DE", "fr-FR", "es-ES", "es-MX", "it-IT", "pt-BR", "ja-JP", "zh-CN", "ko-KR"]

    private func localeName(_ code: String) -> String {
        VoicePickerView.regionName(code)
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool> {
        Binding(
            get: { services.settings[keyPath: keyPath] },
            set: { services.settings[keyPath: keyPath] = $0 }
        )
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, SettingsStore.EndpointProfile>) -> Binding<SettingsStore.EndpointProfile> {
        Binding(
            get: { services.settings[keyPath: keyPath] },
            set: { services.settings[keyPath: keyPath] = $0 }
        )
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<SettingsStore, String>) -> Binding<String> {
        Binding(
            get: { services.settings[keyPath: keyPath] },
            set: { services.settings[keyPath: keyPath] = $0 }
        )
    }

    private func bindingInt(_ keyPath: ReferenceWritableKeyPath<SettingsStore, Int>) -> Binding<Int> {
        Binding(
            get: { services.settings[keyPath: keyPath] },
            set: { services.settings[keyPath: keyPath] = $0 }
        )
    }
}
