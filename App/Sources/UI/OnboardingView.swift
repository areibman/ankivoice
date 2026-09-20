import SwiftUI

/// Three-screen onboarding (PRD §36): value, ratings, tutorial. Microphone
/// and speech permissions are requested by the engine when the tutorial
/// starts, so the prompts appear in context; voice quality is handled in
/// Settings → Voices once the user has real decks.
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var page = 0
    @State private var tutorialActive = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                intro.tag(0)
                ratings.tag(1)
                tutorial.tag(2)
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

    // MARK: Page 3 — tutorial

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
            footer: {
                Text("iOS will ask for microphone and speech recognition access. Speech is recognized on your iPhone — audio never leaves the device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
            guard let deck = try? SampleContent.ensureTutorialDeck(decks: services.decks, cards: services.cards) else { return }
            let session = StudySessionController(
                decks: services.decks, cards: services.cards, reviews: services.reviews,
                queue: services.queue, settings: services.settings
            )
            controller = session
            await session.start(deck: deck, engine: SpeechVoiceEngine())
        }
    }
}

