import SwiftUI

/// Global settings: voices, listening behaviour, study preferences. Backup
/// and diagnostics live one level down under Advanced.
struct SettingsView: View {
    @Environment(AppServices.self) private var services

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
                    Text("Pick the voice that reads cards in each language, or leave it on Automatic for the most natural one installed. Commands like “good” and “repeat” are recognized in the command language.")
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
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Label("Advanced", systemImage: "wrench.and.screwdriver")
                    }
                } footer: {
                    Text("AnkiVoice \(Self.versionString) · FSRS-6 scheduling, on device. Speech is recognized on your iPhone; spoken answers are never stored or sent anywhere.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { inventory.refresh() }
        }
    }

    @State private var inventory = VoiceInventory.shared

    private var voiceStatus: VoiceQualityStatus {
        VoiceQualityStatus(locale: services.settings.commandLocale, inventory: inventory, settings: services.settings)
    }

    private var voiceSummary: String {
        let status = voiceStatus
        guard let voice = status.voice else { return "No voice installed" }
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

/// Rarely needed: backups, diagnostics, about.
struct AdvancedSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var backupURL: URL?
    @State private var backupError: String?

    var body: some View {
        Form {
            Section {
                Button {
                    createBackup()
                } label: {
                    Label("Create full backup", systemImage: "externaldrive.badge.timemachine")
                }
                if let backupError {
                    Text(backupError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Bundles the database and all media into one file you can share or save. Everything stays on this device.")
            }

            Section {
                NavigationLink {
                    DiagnosticDumpView()
                } label: {
                    Label("Diagnostic report", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Raw speech, voice and crash information to paste into a bug report.")
            }

            Section {
                LabeledContent("Version", value: SettingsView.versionString)
                LabeledContent("Scheduler", value: "FSRS-6 (on-device)")
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $backupURL) { url in
            ShareSheet(items: [url])
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
}
