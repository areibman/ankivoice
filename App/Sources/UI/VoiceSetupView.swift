import SwiftUI

/// Tells the user exactly what's wrong with their voice setup and how to
/// fix it. Speech recognition (dictation) and card reading (iOS voices or
/// Supertonic 3) are separate: missing dictation falls back to touch,
/// while a robotic reading voice is fixed by downloading an iOS Premium
/// voice or the on-device Supertonic model.
struct VoiceSetupView: View {
    @Environment(AppServices.self) private var services
    @State private var inventory = VoiceInventory.shared
    @State private var report: DeviceSpeechReport?
    @State private var showGuide = false
    @State private var supertonic = SupertonicTTS.shared

    var body: some View {
        Form {
            if let report {
                recognitionSection(report)
            }
            voiceSection
            supertonicSetupSection
            Section {
                Button {
                    refresh()
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
            } footer: {
                Text("Voices are re-checked automatically when you return from the Settings app.")
            }
        }
        .navigationTitle("Voice setup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
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
                    ok: false, title: "Dictation model not installed",
                    detail: "This is Apple’s on-device speech recognition, not the Supertonic reading voice. Turn on Dictation in Settings → General → Keyboard. iOS then downloads the \(VoicePickerView.regionName(report.commandLocale)) model (Wi‑Fi recommended), which AnkiVoice uses to recognize you entirely on this iPhone."
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
                if voice.kind == .supertonic3 {
                    statusRow(ok: true, title: "\(voice.name) · Supertonic 3", detail: "Cards are read on this iPhone with an on-device neural voice. The model downloads once (about 400 MB).")
                } else if let better = status.betterInstalled {
                    statusRow(ok: false, title: "\(voice.name) · built-in (your pick)", detail: "\(better.name) (\(better.qualityTitle)) is installed and sounds far more natural. Choose it — or Automatic — under Voices; nothing to download.")
                } else {
                    switch voice.quality {
                    case .premium:
                        statusRow(ok: true, title: "\(voice.name) · Premium", detail: "The most natural voice iOS offers.")
                    case .enhanced:
                        statusRow(ok: true, title: "\(voice.name) · Enhanced", detail: "Sounds good; a free Premium voice sounds even better.")
                    case .compact:
                        statusRow(ok: false, title: "Robotic voice", detail: "Only \(voice.name), the basic built-in voice, is installed. Natural iOS voices are a free download — Siri's voices don't count, apps can't use them. Or download Supertonic 3 below for on-device neural speech.")
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
            if !status.isPremium && status.betterInstalled == nil && status.voice?.kind != .supertonic3 {
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

    private var supertonicSetupSection: some View {
        Section {
            switch supertonic.phase {
            case .idle:
                Button {
                    Task { try? await supertonic.prepare() }
                } label: {
                    Label("Download model (~400 MB)", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("voicesetup.supertonic.download")
            case .downloading:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Downloading on-device model…")
                    }
                    if let fraction = supertonic.downloadFraction, fraction > 0 {
                        ProgressView(value: fraction)
                        Text("\(Int(fraction * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            case .ready:
                statusRow(ok: true, title: "Model on this iPhone", detail: "Pick a speaker under Voices. Automatic never uses it.")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button {
                        Task { try? await supertonic.prepare() }
                    } label: {
                        Label("Retry download", systemImage: "arrow.clockwise")
                    }
                }
            }
            NavigationLink {
                VoicePickerView(initialLocale: services.settings.commandLocale)
            } label: {
                Label("Choose a Supertonic speaker", systemImage: "person.wave.2")
            }
        } header: {
            Text("Supertonic 3")
        } footer: {
            Text("A neural reading voice that runs on this iPhone. Separate from the dictation model above. Ten speakers; one ~400 MB download from Hugging Face.")
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

    private func refresh() {
        inventory.refresh()
        report = DeviceSpeechCapabilities.report(commandLocale: services.settings.commandLocale)
    }
}
