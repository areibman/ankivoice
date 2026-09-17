import SwiftUI
import AVFAudio
import Speech

/// Five-screen onboarding (PRD §36): under two minutes end to end.
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var page = 0
    @State private var tutorialActive = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                intro.tag(0)
                ratings.tag(1)
                permission.tag(2)
                assets.tag(3)
                tutorial.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
        }
        .background(Color(.systemBackground))
        .fullScreenCover(isPresented: $tutorialActive) {
            TutorialSessionCard {
                tutorialActive = false
                onComplete()
            }
        }
    }

    // MARK: Page 1 — value proposition

    private var intro: some View {
        OnboardingPage(
            icon: "waveform",
            title: "Study without touching your phone",
            body: "Listen to a card, answer out loud, hear the solution, and rate yourself. Put the phone in your pocket — everything works by voice, even with the screen locked."
        ) {
            Text("Works with AirPods, offline, entirely on-device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } advance: {
            page = 1
        }
        .padding()
    }

    // MARK: Page 2 — ratings

    private var ratings: some View {
        OnboardingPage(
            icon: "hand.thumbsup",
            title: "Four ratings",
            body: "After hearing the answer, say how it went. Hard means you remembered with difficulty — forgetting is always Again."
        ) {
            VStack(spacing: 10) {
                ratingRow("Again", "Didn't remember", .red)
                ratingRow("Hard", "Remembered with difficulty", .orange)
                ratingRow("Good", "Remembered", .green)
                ratingRow("Easy", "Immediate recall", .blue)
            }
        } advance: {
            page = 2
        }
        .padding()
    }

    private func ratingRow(_ title: String, _ description: String, _ color: Color) -> some View {
        HStack {
            Text(title).font(.headline).frame(width: 70, alignment: .leading)
                .foregroundStyle(color)
            Text(description).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: Page 3 — microphone permission

    @State private var permissionState = ""
    @State private var permissionsGranted = false

    private var permission: some View {
        OnboardingPage(
            icon: "mic.fill",
            title: "Microphone access",
            body: "The microphone hears your answers and commands during study. Speech is recognized on your iPhone — audio never leaves the device.",
            content: {
                VStack(spacing: 12) {
                    Button {
                        requestPermissions()
                    } label: {
                        Label(
                            permissionsGranted ? "Microphone & speech enabled" : "Allow microphone & speech recognition",
                            systemImage: permissionsGranted ? "checkmark.circle.fill" : "mic"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(permissionsGranted)
                    if !permissionState.isEmpty {
                        Text(permissionState)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            },
            advance: { page = 3 },
            advanceTitle: "Continue"
        )
        .padding()
    }

    /// Asks for both permissions here so the first study session isn't
    /// interrupted by system dialogs.
    private func requestPermissions() {
        Task { @MainActor in
            let micGranted = await AVAudioApplication.requestRecordPermission()
            let speechStatus = await withCheckedContinuation { continuation in
                // Handler runs off the main thread; `@Sendable` keeps it from
                // inheriting main-actor isolation (which traps at runtime).
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status)
                }
            }
            switch (micGranted, speechStatus) {
            case (true, .authorized):
                permissionsGranted = true
                permissionState = "All set — hands-free study is enabled."
            case (false, _):
                permissionState = "Microphone access denied. You can enable it later in Settings; until then the app works by touch."
            default:
                permissionState = "Speech recognition denied. You can enable it later in Settings; until then the app works by touch."
            }
        }
    }

    // MARK: Page 4 — speech assets

    @State private var assetState = "Checking installed speech assets…"
    @State private var assetsReady = false
    @State private var tts = TextToSpeech()
    @State private var previewing = false
    @State private var showVoiceGuide = false
    @State private var inventory = VoiceInventory.shared
    @Environment(AppServices.self) private var services

    private var voiceStatus: VoiceQualityStatus {
        VoiceQualityStatus(locale: "en-US", inventory: inventory, settings: services.settings)
    }

    private var assets: some View {
        OnboardingPage(
            icon: "speaker.wave.2.bubble",
            title: "Voice check",
            body: "Two things make hands-free study sound right: the speech model that hears you, and a natural voice that reads your cards.",
            content: {
                VStack(spacing: 10) {
                    checkRow(
                        ok: assetsReady,
                        title: assetsReady ? "Speech recognition ready" : "Speech recognition",
                        detail: assetState
                    )
                    checkRow(
                        ok: voiceStatus.isNatural,
                        title: voiceStatus.isNatural
                            ? "Natural voice ready · \(voiceStatus.voice?.name ?? "")"
                            : "Robotic voice only",
                        detail: voiceStatus.isNatural
                            ? "Tap to hear it."
                            : "iOS ships a basic voice; natural ones are a free download. Siri's voices can't be used by apps."
                    ) {
                        if voiceStatus.isNatural { playVoiceSample() } else { showVoiceGuide = true }
                    }
                    if !voiceStatus.isNatural {
                        Button {
                            showVoiceGuide = true
                        } label: {
                            Label("Get a natural voice", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    } else {
                        Button {
                            playVoiceSample()
                        } label: {
                            Label(previewing ? "Stop" : "Hear the voice", systemImage: previewing ? "stop.fill" : "speaker.wave.2")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            },
            advance: { page = 4 },
            advanceTitle: "Continue"
        )
        .padding()
        .task { await checkAssets() }
        .onDisappear { tts.stopSpeaking() }
        .sheet(isPresented: $showVoiceGuide) {
            NaturalVoiceGuideView(locale: "en-US")
        }
    }

    private func checkRow(ok: Bool, title: String, detail: String, action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func playVoiceSample() {
        if previewing {
            tts.stopSpeaking()
            previewing = false
            return
        }
        // The same voice a study session would use, including any pick
        // the user already made under Voices.
        guard let voice = inventory.effectiveVoice(for: "en-US", settings: services.settings) else { return }
        previewing = true
        Task {
            await tts.preview(voiceIdentifier: voice.identifier, text: VoiceSampleText.sample(for: "en-US"), rate: services.settings.speechRate)
            previewing = false
        }
    }

    private func checkAssets() async {
        assetsReady = false
        guard SpeechTranscriber.isAvailable else {
            assetState = "On-device recognition is unavailable on this device."
            return
        }
        let locale = Locale(identifier: "en-US")
        if await SpeechTranscriber.supportedLocale(equivalentTo: locale) == nil {
            assetState = "English recognition isn't supported on this device."
            return
        }
        let installed = await SpeechTranscriber.installedLocales
        let englishInstalled = installed.contains { $0.identifier.hasPrefix("en") }
        if englishInstalled {
            assetsReady = true
            assetState = "The English model is installed. Hands-free study works offline."
        } else {
            // Trigger the system asset-installation sheet if assets are missing.
            do {
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                    await checkAssets()
                    return
                }
                assetState = "Assets will download on first use. Connect to Wi-Fi once, then study anytime."
            } catch {
                assetState = "Couldn't check assets (\(error.localizedDescription)). They'll download on first use."
            }
        }
    }

    // MARK: Page 5 — tutorial

    private var tutorial: some View {
        OnboardingPage(
            icon: "play.circle",
            title: "Try a three-card tutorial",
            body: "Experience the whole interaction before importing anything: listen, answer out loud, hear the answer, and rate yourself by voice.",
            content: {
                Button {
                    tutorialActive = true
                } label: {
                    Label("Start tutorial", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            },
            advance: { onComplete() },
            advanceTitle: "Skip"
        )
        .padding()
    }
}

// MARK: - Page scaffold

private struct OnboardingPage<Content: View, Footer: View>: View {
    let icon: String
    let title: String
    let body_: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    let advance: () -> Void
    var advanceTitle: String = "Continue"

    init(
        icon: String, title: String, body: String,
        @ViewBuilder content: () -> Content = { EmptyView() },
        @ViewBuilder footer: () -> Footer = { EmptyView() },
        advance: @escaping () -> Void,
        advanceTitle: String = "Continue"
    ) {
        self.icon = icon
        self.title = title
        self.body_ = body
        self.content = content()
        self.footer = footer()
        self.advance = advance
        self.advanceTitle = advanceTitle
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(body_)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            content
            Spacer()
            footer
            Button(advanceTitle) { advance() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("onboarding.advance")
        }
        // Keep the button clear of the TabView page dots, which the system
        // renders across the full width at the very bottom.
        .padding(.bottom, 44)
    }
}

// MARK: - Tutorial session

/// Wraps the real session engine over the seeded Tutorial deck.
private struct TutorialSessionCard: View {
    @Environment(AppServices.self) private var services
    let onExit: () -> Void

    @State private var controller: StudySessionController?

    var body: some View {
        NavigationStack {
            Group {
                if let controller {
                    SessionBody(controller: controller, onExit: onExit)
                } else {
                    ProgressView("Preparing tutorial…")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task {
                            await controller?.stop()
                            onExit()
                        }
                    }
                }
            }
        }
        .task {
            guard controller == nil else { return }
            try? SampleContent.seedIfNeeded(decks: services.decks, cards: services.cards)
            guard let deck = try? services.decks.deck(named: SampleContent.tutorialDeckName) else { return }
            let session = StudySessionController(
                decks: services.decks, cards: services.cards, reviews: services.reviews,
                queue: services.queue, settings: services.settings
            )
            controller = session
            await session.start(deck: deck, engine: SpeechVoiceEngine())
        }
    }
}

