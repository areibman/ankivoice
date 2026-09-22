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
    @State private var optimizing = false
    @State private var optimizeMessage: String?
    @State private var speechGroups: [SpeechFieldGroup] = []
    @State private var customizedSpeech: Set<Int64> = []

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
                Text("Leave voices on Default to use the ones chosen in Settings ▸ Voices. How long a pause ends your answer is set for all decks under Settings ▸ Response speed.")
            }

            if !speechGroups.isEmpty {
                Section {
                    ForEach(speechGroups) { group in
                        Text(group.name)
                            .font(.subheadline.weight(.semibold))
                        ForEach(group.fields, id: \.self) { field in
                            HStack {
                                Text(field)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Toggle("Front", isOn: speechToggle(group: group.id, field: field, side: .question))
                                    .labelsHidden()
                                    .accessibilityLabel("\(field) on the front")
                                Text("Front")
                                    .font(.caption)
                                    .foregroundStyle(group.question.contains(field) ? Color.primary : Color.secondary)
                                Toggle("Back", isOn: speechToggle(group: group.id, field: field, side: .answer))
                                    .labelsHidden()
                                    .accessibilityLabel("\(field) on the back")
                                Text("Back")
                                    .font(.caption)
                                    .foregroundStyle(group.answer.contains(field) ? Color.primary : Color.secondary)
                            }
                        }
                        if customizedSpeech.contains(group.id) {
                            Button("Use automatic") { resetSpeech(group.id) }
                        }
                    }
                } header: {
                    Text("Read aloud")
                } footer: {
                    Text("By default the voice reads the first field on each side that changes from card to card, and skips a line that stays the same, like a topic name. Turn fields on or off if it picks the wrong ones.")
                }
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
                Text("Higher retention means shorter intervals and more reviews per day. 90% is a good default. Intervals inside the fuzz window use Anki's load balancer.")
            }

            Section {
                Toggle("Bury new siblings", isOn: $study.buryNewSiblings)
                Toggle("Bury review siblings", isOn: $study.buryReviewSiblings)
                Toggle("Bury interday learning siblings", isOn: $study.buryInterdayLearning)
            } header: {
                Text("Bury related cards")
            } footer: {
                Text("Anki's defaults: new siblings stay hidden until tomorrow, review siblings do not. Interday learning means a sibling whose next step is on a later day.")
            }

            Section {
                easyDaysRow
            } header: {
                Text("Easy days")
            } footer: {
                Text("Part of the load balancer. Tap a day to cycle normal, reduced, and minimum. Reduced days take about half the load.")
            }

            Section {
                Button {
                    optimize()
                } label: {
                    Label(optimizing ? "Optimizing…" : "Optimize FSRS", systemImage: "function")
                }
                .disabled(optimizing)
                if let optimizeMessage {
                    Text(optimizeMessage).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Fits this deck's review history with the same FSRS-6 loss Anki's optimizer uses. Needs at least \(FSRSOptimizer.minimumReviews) reviews.")
            }
        }
        .navigationTitle("Deck Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: voice.questionLocale) { old, new in
            guard loaded else { return }
            dropVoiceThatCannotSpeak(\.questionVoice, locale: new, previous: old)
        }
        .onChange(of: voice.answerLocale) { old, new in
            guard loaded else { return }
            dropVoiceThatCannotSpeak(\.answerVoice, locale: new, previous: old)
        }
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

    private var easyDaysRow: some View {
        let labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return HStack {
            ForEach(0..<7, id: \.self) { index in
                let value = index < study.easyDays.count ? study.easyDays[index] : 1
                Button {
                    var days = study.easyDays.count == 7 ? study.easyDays : Array(repeating: 1.0, count: 7)
                    if value >= 0.99 { days[index] = 0.5 }
                    else if value >= 0.4 { days[index] = 0 }
                    else { days[index] = 1 }
                    study.easyDays = days
                } label: {
                    Text(labels[index])
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(value >= 0.99 ? .accentColor : (value <= 0.01 ? .secondary : .orange))
            }
        }
    }

    private func optimize() {
        optimizing = true
        optimizeMessage = nil
        let deckID = deckID
        let reviews = services.reviews
        let cards = services.cards
        Task {
            defer { optimizing = false }
            do {
                let ids = try cards.descendantDeckIDs(including: deckID)
                let logs = try reviews.history(inDeckIDs: ids)
                let report = try await Task.detached(priority: .userInitiated) {
                    try FSRSOptimizer().optimize(logs: logs)
                }.value
                study.parameters = report.parameters
                optimizeMessage = String(
                    format: "Fit %d reviews. Loss %.3f → %.3f.",
                    report.reviewCount, report.lossBefore, report.lossAfter
                )
            } catch let failure as FSRSOptimizer.Failure {
                if case .notEnoughReviews(let have, let need) = failure {
                    optimizeMessage = "Need \(need) reviews to optimize. This deck has \(have)."
                }
            } catch {
                optimizeMessage = error.localizedDescription
            }
        }
    }

    private func load() {
        let configs = (try? services.decks.config(for: deckID)) ?? (StudyConfig(), VoiceConfig(), nil)
        study = configs.0
        voice = configs.1
        installedVoices = AppVoiceCatalog().voices(matching: "")
        loadSpeechFields()
        loaded = true
    }

    private func loadSpeechFields() {
        let saved = (try? services.decks.spokenFieldChoices(for: deckID)) ?? [:]
        let ids = (try? services.cards.descendantDeckIDs(including: deckID)) ?? [deckID]
        let sample = (try? services.cards.sampleStudyCards(inDeckIDs: ids, limit: 80)) ?? []
        let samples = SpokenFieldPlanner.samples(from: sample)
        var groups: [SpeechFieldGroup] = []
        var custom: Set<Int64> = []
        let types = Dictionary(grouping: sample, by: \.noteType.id).map(\.value.first!.noteType)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for type in types {
            let fieldSamples = samples[type.id] ?? [:]
            var question: Set<String> = []
            var answer: Set<String> = []
            let templates = type.templates.isEmpty ? [NoteTemplate(name: "Card", questionFormat: "", answerFormat: "", ordinal: 0)] : type.templates
            for template in templates {
                question.formUnion(SpokenFieldPlanner.choose(
                    shown: SpokenFieldPlanner.fields(in: template.questionFormat), samples: fieldSamples
                ))
                answer.formUnion(SpokenFieldPlanner.choose(
                    shown: SpokenFieldPlanner.fields(in: template.answerFormat), samples: fieldSamples
                ))
            }
            if let choice = saved[type.id] {
                question = Set(choice.question)
                answer = Set(choice.answer)
                custom.insert(type.id)
            }
            groups.append(SpeechFieldGroup(
                id: type.id, name: type.name, fields: type.fieldNames,
                question: question, answer: answer
            ))
        }
        speechGroups = groups
        customizedSpeech = custom
    }

    private func speechToggle(group id: Int64, field: String, side: SpeechSide) -> Binding<Bool> {
        Binding(
            get: {
                guard let group = speechGroups.first(where: { $0.id == id }) else { return false }
                return side == .question ? group.question.contains(field) : group.answer.contains(field)
            },
            set: { on in
                guard let index = speechGroups.firstIndex(where: { $0.id == id }) else { return }
                if side == .question {
                    if on { speechGroups[index].question.insert(field) }
                    else { speechGroups[index].question.remove(field) }
                } else if on {
                    speechGroups[index].answer.insert(field)
                } else {
                    speechGroups[index].answer.remove(field)
                }
                customizedSpeech.insert(id)
                saveSpeechFields()
            }
        )
    }

    private func resetSpeech(_ id: Int64) {
        customizedSpeech.remove(id)
        saveSpeechFields()
        loadSpeechFields()
    }

    private func saveSpeechFields() {
        var stored: [Int64: SpokenFieldChoice] = [:]
        for group in speechGroups where customizedSpeech.contains(group.id) {
            stored[group.id] = SpokenFieldChoice(
                question: group.fields.filter { group.question.contains($0) },
                answer: group.fields.filter { group.answer.contains($0) }
            )
        }
        try? services.decks.updateSpokenFieldChoices(stored, for: deckID)
    }

    /// An Apple voice pinned to the old language can't read the new one.
    /// Clearing it lets the same Supertonic speaker, if one was chosen, stay
    /// as the default. A voice that already speaks the new language stays.
    private func dropVoiceThatCannotSpeak(
        _ key: WritableKeyPath<VoiceConfig, String?>,
        locale: String,
        previous: String
    ) {
        guard SettingsStore.languageKey(for: previous) != SettingsStore.languageKey(for: locale) else { return }
        guard let current = voice[keyPath: key], !speaks(current, locale) else { return }
        voice[keyPath: key] = nil
    }

    private func speaks(_ identifier: String, _ locale: String) -> Bool {
        let key = SettingsStore.languageKey(for: locale)
        if SupertonicVoiceCatalog.isSupertonic(identifier) {
            return SupertonicVoiceCatalog.supports(languageKey: key)
        }
        return installedVoices.contains {
            $0.identifier == identifier && SettingsStore.languageKey(for: $0.language) == key
        }
    }

    private func voiceName(_ identifier: String?, locale: String) -> String {
        if let identifier, let match = installedVoices.first(where: { $0.identifier == identifier }) {
            return match.name
        }
        if let fallback = services.settings.effectiveDefaultVoice(forLocale: locale),
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

private struct SpeechFieldGroup: Identifiable {
    var id: Int64
    var name: String
    var fields: [String]
    var question: Set<String>
    var answer: Set<String>
}
