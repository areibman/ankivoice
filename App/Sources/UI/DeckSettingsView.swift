import SwiftUI
import AVFoundation

/// Deck settings: languages and voices for each card side, speaking speed,
/// and FSRS study limits. Changes save as you go.
struct DeckSettingsView: View {
    @Environment(AppServices.self) private var services
    let deckID: Int64

    @State private var study = StudyConfig()
    @State private var voice = VoiceConfig()
    @State private var loaded = false
    @State private var installedVoices: [VoiceCatalogVoice] = []

    var body: some View {
        Form {
            Section {
                Picker("Front (question)", selection: $voice.questionLocale) {
                    ForEach(localeOptions(including: voice.questionLocale), id: \.self) { locale in
                        Text(VoicePickerView.regionName(locale)).tag(locale)
                    }
                }
                Picker("Back (answer)", selection: $voice.answerLocale) {
                    ForEach(localeOptions(including: voice.answerLocale), id: \.self) { locale in
                        Text(VoicePickerView.regionName(locale)).tag(locale)
                    }
                }
            } header: {
                Text("Languages")
            } footer: {
                Text("Set the language of each side so cards are pronounced correctly — e.g. Japanese on the front, English on the back.")
            }

            Section {
                NavigationLink {
                    VoicePickerView(mode: .choose(
                        locale: voice.questionLocale, title: "Question voice",
                        selection: $voice.questionVoice
                    ))
                } label: {
                    LabeledContent("Question voice", value: voiceName(voice.questionVoice, locale: voice.questionLocale))
                }
                NavigationLink {
                    VoicePickerView(mode: .choose(
                        locale: voice.answerLocale, title: "Answer voice",
                        selection: $voice.answerVoice
                    ))
                } label: {
                    LabeledContent("Answer voice", value: voiceName(voice.answerVoice, locale: voice.answerLocale))
                }
                Toggle("Use default speed", isOn: $voice.usesDefaultSpeechRate)
                if !voice.usesDefaultSpeechRate {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Speaking speed")
                            Spacer()
                            Text(String(format: "%.1f×", voice.speechRate))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $voice.speechRate, in: 0.5...2.0, step: 0.1)
                    }
                }
            } header: {
                Text("Voices")
            } footer: {
                Text("Leave voices on Default to use the ones chosen in Settings ▸ Voices.")
            }

            Section {
                Picker("Answer pause", selection: $voice.endpointDelayMs) {
                    Text("Short (0.5s)").tag(500)
                    Text("Normal (0.7s)").tag(700)
                    Text("Long (0.9s)").tag(900)
                }
            } header: {
                Text("Listening")
            } footer: {
                Text("How long you can pause mid-answer before the app decides you're done.")
            }

            Section {
                Stepper(value: $study.newPerDay, in: 0...200) {
                    LabeledContent("New cards per day", value: "\(study.newPerDay)")
                }
                Stepper(value: $study.reviewsPerDay, in: 0...999, step: 10) {
                    LabeledContent("Reviews per day", value: "\(study.reviewsPerDay)")
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Desired retention", value: String(format: "%.0f%%", study.desiredRetention * 100))
                    Slider(value: $study.desiredRetention, in: 0.7...0.99, step: 0.01)
                }
                Stepper(value: $study.maximumIntervalDays, in: 30...36_500, step: 30) {
                    LabeledContent("Maximum interval", value: "\(study.maximumIntervalDays) days")
                }
            } header: {
                Text("Scheduling")
            } footer: {
                Text("Higher retention means shorter intervals and more reviews per day. 90% is a good default.")
            }
        }
        .navigationTitle("Deck Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: voice) { _, newValue in
            guard loaded else { return }
            try? services.decks.updateVoiceConfig(newValue, for: deckID)
        }
        .onChange(of: study) { _, newValue in
            guard loaded else { return }
            try? services.decks.updateStudyConfig(newValue, for: deckID)
        }
    }

    // MARK: Helpers

    private func load() {
        let configs = (try? services.decks.config(for: deckID)) ?? (StudyConfig(), VoiceConfig(), nil)
        study = configs.0
        voice = configs.1
        installedVoices = SystemVoiceCatalog().voices(matching: "")
        loaded = true
    }

    private func voiceName(_ identifier: String?, locale: String) -> String {
        if let identifier, let match = installedVoices.first(where: { $0.identifier == identifier }) {
            return match.name
        }
        if let fallback = services.settings.defaultVoice(forLocale: locale),
           let match = installedVoices.first(where: { $0.identifier == fallback }) {
            return "Default (\(match.name))"
        }
        return "Default"
    }

    /// Common locales plus every locale with an installed voice, so users
    /// can pick any language their phone can speak.
    private func localeOptions(including current: String) -> [String] {
        var set = Set(Self.commonLocales)
        set.insert(current)
        for v in installedVoices where !v.isNovelty { set.insert(v.language) }
        return set.sorted {
            VoicePickerView.regionName($0).localizedCaseInsensitiveCompare(VoicePickerView.regionName($1)) == .orderedAscending
        }
    }

    private static let commonLocales: [String] = [
        "en-US", "en-GB", "ja-JP", "fr-FR", "de-DE", "es-ES", "es-MX", "it-IT",
        "pt-BR", "zh-CN", "ko-KR", "ru-RU", "ar-SA", "hi-IN", "nl-NL",
        "pl-PL", "tr-TR", "sv-SE", "th-TH", "vi-VN", "he-IL",
    ]
}
