import SwiftUI
import AVFAudio
import UIKit

/// Lists the voices installed on this iPhone, grouped by language and
/// quality, with one-tap preview. Tapping a voice selects it; the play
/// button only previews.
///
/// Two modes share the screen:
/// - `.defaults` (Settings ▸ Voices): pick the default voice per language
///   and the global speaking speed.
/// - `.choose` (Deck settings): pick an explicit voice for one card side,
///   or fall back to the default.
///
/// The list is live: a voice downloaded in the Settings app shows up the
/// moment you switch back.
struct VoicePickerView: View {
    enum Mode {
        case defaults
        case choose(locale: String, title: String, selection: Binding<String?>)
    }

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    /// Language to open on in `.defaults` mode (a deck's locale, say).
    /// Falls back to the command language.
    let initialLocale: String?

    @State private var inventory = VoiceInventory.shared
    @State private var languageKey: String = "en"
    @State private var showNovelty = false
    @State private var speaking: String?
    @State private var speechRate: Double = 1.0
    @State private var showGuide = false
    @State private var tts = TextToSpeech()
    @State private var supertonic = SupertonicTTS.shared

    init(mode: Mode = .defaults, initialLocale: String? = nil) {
        self.mode = mode
        self.initialLocale = initialLocale
    }

    var body: some View {
        List {
            if case .defaults = mode {
                languageSection
            }
            statusSection
            supertonicSection
            defaultRowSection
            voiceSections
            if case .defaults = mode {
                speedSection
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear { tts.stopSpeaking() }
        .sensoryFeedback(.selection, trigger: currentSelection)
        .sheet(isPresented: $showGuide) {
            NaturalVoiceGuideView(locale: requestedLocale)
                .presentationDetents([.large])
        }
    }

    // MARK: Sections

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $languageKey) {
                ForEach(languageKeys, id: \.self) { key in
                    Text(Self.languageName(key)).tag(key)
                }
            }
            .pickerStyle(.navigationLink)
        } footer: {
            Text("Cards are read in the language set on each deck. Pick the voice you want for each language you study.")
        }
    }

    /// One glance: is this language going to sound natural or robotic, and
    /// is that because of what's installed or because of what was picked?
    @ViewBuilder
    private var statusSection: some View {
        let status = self.status
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: status.isNatural ? "checkmark.seal.fill" : "waveform.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(status.isNatural ? .green : .orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle(status))
                            .font(.headline)
                        Text(statusBody(status))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let better = status.betterInstalled {
                    Button {
                        select(better.identifier)
                    } label: {
                        Label("Use \(better.name)", systemImage: "arrow.up.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("voices.useBetter")
                } else if showsGuideButton(for: status) {
                    Button {
                        showGuide = true
                    } label: {
                        Label(status.isNatural ? "Get a Premium voice" : "Get a natural voice", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(status.isNatural ? .accentColor : .orange)
                    .accessibilityIdentifier("voices.guide")
                }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((status.isNatural ? Color.green : Color.orange).opacity(0.08))
        )
    }

    /// Premium is the ceiling; everything below it gets a nudge — unless a
    /// better voice is already installed, in which case the fix is a tap.
    private func showsGuideButton(for status: VoiceQualityStatus) -> Bool {
        guard status.voice?.kind != .supertonic3 else { return false }
        return !status.isPremium && status.betterInstalled == nil
    }

    private func statusTitle(_ status: VoiceQualityStatus) -> String {
        guard let voice = status.voice else { return "No \(Self.languageName(languageKey)) voice" }
        if voice.kind == .supertonic3 {
            return "\(voice.name) · Supertonic 3"
        }
        switch voice.quality {
        case .premium: return "\(voice.name) · Premium"
        case .enhanced: return "\(voice.name) · Enhanced"
        case .compact: return status.isExplicit ? "\(voice.name) · built-in" : "Robotic voice"
        }
    }

    private func statusBody(_ status: VoiceQualityStatus) -> String {
        let language = Self.languageName(languageKey)
        guard let voice = status.voice else {
            return "Cards in this language can't be read until a voice is downloaded."
        }
        if voice.kind == .supertonic3 {
            switch supertonic.phase {
            case .downloading:
                return "Downloading the on-device model (about 400 MB). After that, \(language) cards are read entirely on this iPhone."
            case .failed(let message):
                return "Couldn't download Supertonic 3: \(message). Tap a voice below to retry, or pick an iOS voice."
            default:
                return "\(voice.name) reads \(language) cards on this iPhone with Supertonic 3 — no Apple voice download needed."
            }
        }
        if let better = status.betterInstalled {
            return "\(better.name) (\(better.qualityTitle)) is installed and sounds far more natural. Tap it below, or choose \(defaultRowTitle)."
        }
        switch voice.quality {
        case .premium:
            return "The most natural \(language) voice iOS offers is \(status.isExplicit ? "selected" : "installed and in use")."
        case .enhanced:
            return "Sounds good. A free Premium voice sounds even closer to a real person."
        case .compact:
            let extra = " Or download Supertonic 3 below — one on-device model, then it reads cards locally."
            return status.isExplicit
                ? "\(voice.name) is a basic built-in voice — the only iOS kind installed for \(language). Natural voices are a free download.\(extra)"
                : "Only \(voice.name), the basic built-in voice, is installed for \(language). Natural voices are a free download.\(extra)"
        }
    }

    private var speedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Speaking speed")
                    Spacer()
                    Text(String(format: "%.1f×", speechRate))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speechRate, in: 0.5...2.0, step: 0.1) {
                    Text("Speaking speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
                .onChange(of: speechRate) { _, rate in
                    services.settings.speechRate = rate
                }
            }
        } footer: {
            Text("Decks use this speed unless they set their own.")
        }
    }

    private var defaultRowSection: some View {
        Section {
            Button {
                select(nil)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(defaultRowTitle)
                            .foregroundStyle(.primary)
                        Text(defaultRowSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if currentSelection == nil {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voices.auto")
        } header: {
            Text(Self.languageName(languageKey))
        } footer: {
            if case .choose = mode {
                Text("The default is set in Settings ▸ Voices. Choosing a voice here overrides it for this deck.")
            } else {
                Text("Tap a voice to use it for \(Self.languageName(languageKey)) cards. Automatic always uses the most natural installed voice: Premium, then Enhanced, then built-in.")
            }
        }
    }

    @ViewBuilder
    private var supertonicSection: some View {
        Section {
            downloadRow
            ForEach(supertonicVoices, id: \.identifier) { voice in
                voiceRow(voice, subtitle: voice.qualityTitle)
            }
        } header: {
            Text("Supertonic 3 — on device")
        } footer: {
            Text(supertonicFooter)
        }
    }

    @ViewBuilder
    private var downloadRow: some View {
        switch supertonic.phase {
        case .idle:
            Button {
                startSupertonicDownload()
            } label: {
                Label("Download model (~400 MB)", systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("voices.supertonic.download")
        case .downloading:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Downloading on-device model…")
                        .foregroundStyle(.secondary)
                }
                if let fraction = supertonic.downloadFraction, fraction > 0 {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))% of about 400 MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityIdentifier("voices.supertonic.downloading")
        case .ready:
            Label("Model on this iPhone", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("voices.supertonic.ready")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button {
                    startSupertonicDownload()
                } label: {
                    Label("Retry download", systemImage: "arrow.clockwise")
                }
            }
            .accessibilityIdentifier("voices.supertonic.failed")
        }
    }

    private var supertonicFooter: String {
        let language = Self.languageName(languageKey)
        if SupertonicVoiceCatalog.supports(languageKey: languageKey) {
            return "Ten speakers for \(language). Download the CoreML pack once (Wi‑Fi, about 400 MB from Hugging Face); after that it runs entirely on this iPhone. Automatic never picks it."
        }
        return "Ten speakers. \(language) isn’t in the 31-language training set, so cards use the model’s language-agnostic mode. Download the CoreML pack once (Wi‑Fi, about 400 MB); Automatic never picks it."
    }

    private func startSupertonicDownload() {
        Task {
            try? await supertonic.prepare()
        }
    }

    @ViewBuilder
    private var voiceSections: some View {
        let grouped = groupedVoices
        ForEach(VoiceQualityTier.allCasesDescending, id: \.self) { tier in
            if let voices = grouped[tier], !voices.isEmpty {
                Section {
                    ForEach(voices) { voice in
                        voiceRow(voice)
                    }
                } header: {
                    Text(Self.tierHeader(tier))
                }
            }
        }
        Section {
            if hasNovelty {
                Toggle("Show novelty voices", isOn: $showNovelty)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if hasNovelty {
                    Text("Character and legacy voices (Bad News, Bubbles, Eddy…). They're never chosen automatically.")
                }
                Text("Looking for Siri's voices? Apple reserves them for Siri — no app can use them, so they never appear here. Natural voices for apps are a free download under Settings → Accessibility → Read & Speak → Voices.")
            }
        }
    }

    private func voiceRow(_ voice: VoiceCatalogVoice, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            Button {
                select(voice.identifier)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(voice.name)
                                .foregroundStyle(.primary)
                            if voice.isPersonal {
                                Text("Personal")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.thinMaterial, in: Capsule())
                            }
                        }
                        Text(subtitle ?? Self.regionName(voice.language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if currentSelection == voice.identifier {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voices.pick.\(voice.identifier)")
            .accessibilityAddTraits(currentSelection == voice.identifier ? .isSelected : [])

            Button {
                preview(voice)
            } label: {
                Image(systemName: speaking == voice.identifier ? "stop.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speaking == voice.identifier ? "Stop preview" : "Preview \(voice.name)")
        }
    }

    // MARK: Data

    private var allVoices: [VoiceCatalogVoice] { inventory.voices }

    private var status: VoiceQualityStatus {
        switch mode {
        case .defaults:
            return VoiceQualityStatus(locale: requestedLocale, inventory: inventory, settings: services.settings)
        case .choose(let locale, _, let selection):
            return VoiceQualityStatus(locale: locale, inventory: inventory, settings: services.settings, deckVoice: selection.wrappedValue)
        }
    }

    private var title: String {
        switch mode {
        case .defaults: return "Voices"
        case .choose(_, let title, _): return title
        }
    }

    private var defaultRowTitle: String {
        switch mode {
        case .defaults: return "Automatic"
        case .choose: return "Use default voice"
        }
    }

    /// What the default row would actually play, so the choice is informed.
    private var defaultRowSubtitle: String {
        switch mode {
        case .defaults:
            guard let auto = inventory.automaticVoice(for: requestedLocale) else {
                return "No voice installed for this language"
            }
            return "Most natural installed voice · currently \(auto.name)"
        case .choose(let locale, _, _):
            guard let voice = inventory.effectiveVoice(for: locale, settings: services.settings) else {
                return "No voice installed for this language"
            }
            let source = inventory.chosenVoice(for: locale, settings: services.settings) == nil ? "Automatic" : "Settings ▸ Voices"
            return "\(voice.name) · from \(source)"
        }
    }

    private var currentSelection: String? {
        switch mode {
        case .defaults:
            return services.settings.defaultVoice(forLocale: languageKey)
        case .choose(_, _, let selection):
            return selection.wrappedValue
        }
    }

    private var languageKeys: [String] {
        var keys = Set(allVoices.map(\.languageKey))
        keys.insert(languageKey)
        let preferred = Locale.preferredLanguages.map { SettingsStore.languageKey(for: $0) }
        return keys.sorted { a, b in
            let ia = preferred.firstIndex(of: a) ?? Int.max
            let ib = preferred.firstIndex(of: b) ?? Int.max
            if ia != ib { return ia < ib }
            return Self.languageName(a).localizedCaseInsensitiveCompare(Self.languageName(b)) == .orderedAscending
        }
    }

    private var localizedVoices: [VoiceCatalogVoice] {
        inventory.voices(forLanguage: languageKey)
    }

    private var appleVoices: [VoiceCatalogVoice] {
        localizedVoices.filter { $0.kind == .apple }
    }

    private var supertonicVoices: [VoiceCatalogVoice] {
        // Always list the ten speakers from the catalog, not the inventory
        // snapshot — unsupported languages (Chinese, Thai, …) have Apple
        // voices but used to hide this whole section.
        SupertonicVoiceCatalog.voices(matching: languageKey)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var hasNovelty: Bool {
        appleVoices.contains(where: \.isNovelty)
    }

    private var groupedVoices: [VoiceQualityTier: [VoiceCatalogVoice]] {
        let visible = appleVoices.filter { showNovelty || !$0.isNovelty }
        var groups: [VoiceQualityTier: [VoiceCatalogVoice]] = [:]
        for voice in visible {
            groups[voice.quality, default: []].append(voice)
        }
        for key in groups.keys {
            groups[key]?.sort { a, b in
                if a.language != b.language {
                    // The exact requested region first, then alphabetically.
                    let ra = a.language.caseInsensitiveCompare(requestedLocale) == .orderedSame
                    let rb = b.language.caseInsensitiveCompare(requestedLocale) == .orderedSame
                    if ra != rb { return ra }
                    return a.language < b.language
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return groups
    }

    /// The locale automatic selection is judged against.
    private var requestedLocale: String {
        switch mode {
        case .choose(let locale, _, _): return locale
        case .defaults:
            let candidates = [initialLocale, services.settings.commandLocale].compactMap { $0 }
            if let match = candidates.first(where: { SettingsStore.languageKey(for: $0) == languageKey }) {
                return match
            }
            return Locale.preferredLanguages.first { SettingsStore.languageKey(for: $0) == languageKey } ?? languageKey
        }
    }

    // MARK: Actions

    private func load() {
        inventory.refresh()
        speechRate = services.settings.speechRate
        switch mode {
        case .choose(let locale, _, _):
            languageKey = SettingsStore.languageKey(for: locale)
        case .defaults:
            languageKey = SettingsStore.languageKey(for: initialLocale ?? services.settings.commandLocale)
        }
    }

    private func select(_ identifier: String?) {
        switch mode {
        case .defaults:
            services.settings.setDefaultVoice(identifier, forLocale: languageKey)
        case .choose(_, _, let selection):
            selection.wrappedValue = identifier
        }
        // Hear the result of the choice right away.
        if let voice = status.voice {
            preview(voice, restart: true)
        }
    }

    private func preview(_ voice: VoiceCatalogVoice, restart: Bool = false) {
        if speaking == voice.identifier && !restart {
            tts.stopSpeaking()
            speaking = nil
            return
        }
        speaking = voice.identifier
        previewGeneration += 1
        let generation = previewGeneration
        let text = VoiceSampleText.sample(for: voice.language)
        let rate = speechRate
        Task {
            await tts.preview(voiceIdentifier: voice.identifier, text: text, rate: rate, locale: voice.language)
            // A newer preview may have interrupted this one; only the latest
            // gets to reset the play button.
            if previewGeneration == generation { speaking = nil }
        }
    }

    @State private var previewGeneration = 0

    // MARK: Names

    static func languageName(_ key: String) -> String {
        Locale.current.localizedString(forLanguageCode: key)?.capitalized(with: .current) ?? key.uppercased()
    }

    static func regionName(_ bcp47: String) -> String {
        let locale = Locale(identifier: bcp47)
        let language = locale.language.languageCode?.identifier ?? bcp47
        let languageName = Locale.current.localizedString(forLanguageCode: language) ?? language
        if let region = locale.region?.identifier,
           let regionName = Locale.current.localizedString(forRegionCode: region) {
            return "\(languageName) (\(regionName))"
        }
        return languageName
    }

    static func tierHeader(_ tier: VoiceQualityTier) -> String {
        switch tier {
        case .premium: return "Premium — most natural"
        case .enhanced: return "Enhanced"
        case .compact: return "Built-in"
        }
    }
}

extension VoiceQualityTier {
    static let allCasesDescending: [VoiceQualityTier] = [.premium, .enhanced, .compact]
}

/// Short, natural sentences for voice previews.
enum VoiceSampleText {
    static func sample(for bcp47: String) -> String {
        switch SettingsStore.languageKey(for: bcp47) {
        case "en": return "This is how your flashcards will sound. Say Good when you remember."
        case "ja": return "これはフラッシュカードの読み上げの例です。"
        case "fr": return "Voici comment vos cartes seront lues."
        case "de": return "So werden deine Karteikarten vorgelesen."
        case "es": return "Así es como sonarán tus tarjetas."
        case "it": return "Ecco come suoneranno le tue schede."
        case "pt": return "É assim que os seus cartões vão soar."
        case "zh", "yue": return "这就是您的抽认卡朗读的效果。"
        case "ko": return "플래시카드는 이렇게 읽어 드립니다."
        case "ru": return "Так будут звучать ваши карточки."
        case "nl": return "Zo zullen je kaarten klinken."
        case "pl": return "Tak będą brzmieć twoje fiszki."
        case "tr": return "Kartlarınız böyle okunacak."
        case "sv": return "Så här kommer dina kort att låta."
        case "da": return "Sådan vil dine kort lyde."
        case "nb", "no": return "Slik vil kortene dine høres ut."
        case "fi": return "Näin korttisi kuulostavat."
        case "ar": return "هكذا ستبدو بطاقاتك التعليمية."
        case "he": return "כך יישמעו הכרטיסיות שלך."
        case "hi": return "आपके फ़्लैशकार्ड ऐसे सुनाई देंगे।"
        case "th": return "การ์ดคำศัพท์ของคุณจะฟังดูแบบนี้"
        case "vi": return "Thẻ ghi nhớ của bạn sẽ nghe như thế này."
        case "id": return "Seperti inilah kartu Anda akan terdengar."
        case "el": return "Έτσι θα ακούγονται οι κάρτες σας."
        case "cs": return "Takto budou znít vaše kartičky."
        case "hu": return "Így fognak hangzani a kártyáid."
        case "ro": return "Așa vor suna cardurile tale."
        case "uk": return "Так звучатимуть ваші картки."
        default: return "This is how your flashcards will sound."
        }
    }
}

/// Deep links into the Settings app. Only the app's own settings page has
/// a public URL; the voice-download pane doesn't, so the guide spells out
/// the path (Accessibility ▸ Read & Speak ▸ Voices).
enum SystemSettingsLinks {
    @MainActor
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
