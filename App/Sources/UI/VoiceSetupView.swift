import SwiftUI
import os

/// Tells the user exactly what's wrong with their voice setup and how to
/// fix it. Two things can go wrong: the speech recognition model isn't
/// installed (hands-free commands fail), or only the robotic built-in voice
/// is installed (cards sound bad). Both are fixed in the Settings app.
private let speechLog = Logger(subsystem: "local.ankivoice", category: "speech-diag")

struct VoiceSetupView: View {
    @Environment(AppServices.self) private var services
    @State private var inventory = VoiceInventory.shared
    @State private var report: DeviceSpeechReport?
    @State private var isLoading = false
    @State private var showGuide = false

    var body: some View {
        Form {
            if let report {
                recognitionSection(report)
                voiceSection
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    HStack {
                        Label("Check again", systemImage: "arrow.clockwise")
                        Spacer()
                        if isLoading { ProgressView() }
                    }
                }
                .disabled(isLoading)
            } footer: {
                Text("Voices are re-checked automatically when you return from the Settings app.")
            }
        }
        .navigationTitle("Voice setup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .sheet(isPresented: $showGuide) {
            NaturalVoiceGuideView(locale: services.settings.commandLocale)
        }
    }

    // MARK: Speech recognition

    private func recognitionSection(_ report: DeviceSpeechReport) -> some View {
        Section {
            if !report.speechRecognitionSupported {
                statusRow(
                    ok: false, title: "Not supported on this iPhone",
                    detail: "Speech recognition isn't available here. The app still works by touch."
                )
            } else if !report.speechAssetsInstalled {
                statusRow(
                    ok: false, title: "Speech model not installed",
                    detail: "Turn on Dictation in Settings → General → Keyboard. iOS then downloads the \(VoicePickerView.regionName(report.commandLocale)) model (~500 MB, Wi‑Fi recommended), which AnkiVoice also uses."
                )
                Button {
                    SystemSettingsLinks.openAppSettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
            } else {
                statusRow(ok: true, title: "Ready — works offline", detail: nil)
            }
        } header: {
            Text("Hearing you · \(VoicePickerView.regionName(report.commandLocale))")
        }
    }

    // MARK: Voices

    private var voiceSection: some View {
        let locale = services.settings.commandLocale
        let status = VoiceQualityStatus(locale: locale, inventory: inventory, settings: services.settings)
        return Section {
            if let voice = status.voice {
                if let better = status.betterInstalled {
                    statusRow(ok: false, title: "\(voice.name) · built-in (your pick)", detail: "\(better.name) (\(better.qualityTitle)) is installed and sounds far more natural. Choose it — or Automatic — under Voices; nothing to download.")
                } else {
                    switch voice.quality {
                    case .premium:
                        statusRow(ok: true, title: "\(voice.name) · Premium", detail: "The most natural voice iOS offers.")
                    case .enhanced:
                        statusRow(ok: true, title: "\(voice.name) · Enhanced", detail: "Sounds good; a free Premium voice sounds even better.")
                    case .compact:
                        statusRow(ok: false, title: "Robotic voice", detail: "Only \(voice.name), the basic built-in voice, is installed. Natural voices are a free download — Siri's voices don't count, apps can't use them.")
                    }
                }
            } else {
                statusRow(ok: false, title: "No voice installed", detail: "Cards can't be read aloud until a voice is downloaded.")
            }
            NavigationLink {
                VoicePickerView(initialLocale: locale)
            } label: {
                Label("Choose a voice", systemImage: "person.wave.2")
            }
            .accessibilityIdentifier("voicesetup.picker")
            if !status.isPremium && status.betterInstalled == nil {
                Button {
                    showGuide = true
                } label: {
                    Label(status.isNatural ? "Get a Premium voice" : "Get a natural voice", systemImage: "arrow.down.circle.fill")
                }
                .accessibilityIdentifier("voicesetup.guide")
            }
        } header: {
            Text("Reading cards · \(VoicePickerView.languageName(SettingsStore.languageKey(for: locale)))")
        }
    }

    private func statusRow(ok: Bool, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        inventory.refresh()
        let live = LiveDeviceSpeechCapabilities()
        let locale = services.settings.commandLocale
        report = await live.report(commandLocale: locale)
        if let r = report {
            speechLog.info("[SPEECH-DIAG] VoiceSetup: supported=\(r.speechRecognitionSupported) assets=\(r.speechAssetsInstalled) voices=\(r.ttsVoicesForLocale.count)")
        }
    }
}
