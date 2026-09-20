import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The hands-free study screen.
///
/// One glance tells the user what the app is doing (speaking, listening,
/// waiting for a rating) and what to say next. Every voice action has a
/// touch equivalent, so a session never traps the user when recognition
/// fails.
struct SessionScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let deckID: Int64
    var gather: StudyQueue.Gather = .scheduled

    @State private var controller: StudySessionController?
    @State private var fatal: String?

    var body: some View {
        NavigationStack {
            Group {
                if let controller {
                    SessionBody(controller: controller, onExit: exit)
                } else if let fatal {
                    ContentUnavailableView(
                        "Couldn't start the session",
                        systemImage: "waveform.slash",
                        description: Text(fatal)
                    )
                } else {
                    ProgressView("Starting session…")
                }
            }
            .navigationTitle(controller?.deck?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("End") { exit() }
                        .accessibilityIdentifier("session.end")
                }
            }
        }
        .interactiveDismissDisabled(controller?.state != .finished)
        .task { await start() }
        .onReceive(NotificationCenter.default.publisher(for: .ankivoiceVoiceSetupRetried)) { _ in
            // Speech assets may have just been installed: restart with a fresh engine.
            guard let controller, !controller.voiceAvailable, controller.state != .finished else { return }
            Task {
                await controller.stop()
                self.controller = nil
                await start()
            }
        }
    }

    private func start() async {
        guard controller == nil, let deck = try? services.decks.deck(id: deckID) else { return }
        let session = StudySessionController(
            decks: services.decks, cards: services.cards, reviews: services.reviews,
            queue: services.queue, settings: services.settings
        )
        session.gather = gather
        controller = session
        await session.start(deck: deck, engine: SpeechVoiceEngine())
        if session.state == .idle, let message = session.statusMessage {
            fatal = message
        }
    }

    private func exit() {
        Task {
            await controller?.stop()
            dismiss()
        }
    }
}

struct SessionBody: View {
    @Environment(AppServices.self) private var services
    let controller: StudySessionController
    let onExit: () -> Void
    /// While the answer is up, a tap shows the question again. The review
    /// itself doesn't go backwards.
    @State private var showingQuestion = false

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            ScrollView {
                VStack(spacing: 20) {
                    if !controller.voiceAvailable, controller.state != .finished {
                        VoiceSetupBanner()
                            .padding(.horizontal)
                    }
                    statusIndicator
                        .padding(.top, 8)
                    if controller.state == .finished {
                        summaryCard
                    } else {
                        cardView
                        transcriptView
                    }
                }
                .padding(.bottom, 16)
            }
            Divider()
            controls
        }
        .background(Color(.systemGroupedBackground))
        .animation(.easeInOut(duration: 0.2), value: controller.state)
    }

    // MARK: Progress

    private var progressBar: some View {
        let done = controller.reviewsThisSession
        let total = max(done + controller.remaining.total, 1)
        return VStack(spacing: 6) {
            ProgressView(value: Double(done), total: Double(total))
                .tint(Color.accentColor)
            HStack {
                Text("\(done) reviewed")
                Spacer()
                Text("\(controller.remaining.total) left")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Status

    private var statusIndicator: some View {
        VStack(spacing: 10) {
            ZStack {
                if indicatorPulses {
                    PulsingRing(color: indicatorColor)
                }
                Circle()
                    .fill(indicatorColor.gradient)
                    .frame(width: 72, height: 72)
                Image(systemName: indicatorSymbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(height: 96)
            .accessibilityHidden(true)

            Text(stateTitle)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let hint = stateHint {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let message = controller.statusMessage, !message.isEmpty, controller.state != .finished {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var indicatorPulses: Bool {
        switch controller.state {
        case .awaitingAnswer, .answerInProgress, .awaitingRating: return controller.voiceAvailable
        case .speakingPrompt, .speakingAnswer: return true
        default: return false
        }
    }

    private var indicatorColor: Color {
        switch controller.state {
        case .speakingPrompt, .speakingAnswer, .loadingCard, .processingRating: return .accentColor
        case .awaitingAnswer, .answerInProgress, .answerComplete: return .orange
        case .awaitingRating: return .indigo
        case .paused: return .gray
        case .finished: return .green
        case .idle: return .gray
        }
    }

    private var indicatorSymbol: String {
        switch controller.state {
        case .speakingPrompt, .speakingAnswer: return "speaker.wave.2.fill"
        case .awaitingAnswer, .answerInProgress: return controller.voiceAvailable ? "mic.fill" : "brain.head.profile"
        case .answerComplete: return "checkmark"
        case .awaitingRating: return controller.voiceAvailable ? "waveform" : "hand.tap.fill"
        case .paused: return "pause.fill"
        case .finished: return "checkmark.seal.fill"
        case .loadingCard, .processingRating, .idle: return "ellipsis"
        }
    }

    private var stateTitle: String {
        let voice = controller.voiceAvailable
        switch controller.state {
        case .idle: return "Not running"
        case .loadingCard: return "Next card…"
        case .speakingPrompt: return "Reading the question"
        case .awaitingAnswer, .answerInProgress: return voice ? "Your turn — answer out loud" : "Think of the answer"
        case .answerComplete: return "Got it"
        case .speakingAnswer: return "Reading the answer"
        case .awaitingRating: return "How did you do?"
        case .processingRating: return "Scheduling…"
        case .paused: return "Paused"
        case .finished: return "Session complete"
        }
    }

    private var stateHint: String? {
        let voice = controller.voiceAvailable
        switch controller.state {
        case .awaitingAnswer, .answerInProgress:
            return voice ? "When you stop talking, the answer is read to you. Say “reveal” to skip ahead." : "Tap Reveal when you're ready."
        case .awaitingRating:
            return voice
                ? (controller.settings.simplifiedRatings ? "Say “again” or “good”." : "Say “again”, “hard”, “good” or “easy”.")
                : "Tap a rating below."
        case .paused:
            return voice ? "Say “resume” or tap the button below." : "Tap Resume to continue."
        case .speakingPrompt:
            return voice ? "Tap the card to flip it, or say “reveal” once it finishes." : "Tap the card to flip it."
        case .speakingAnswer:
            return "Tap the card to see the other side."
        default:
            return nil
        }
    }

    // MARK: Card

    @ViewBuilder
    private var cardView: some View {
        if let card = controller.currentCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(shownSide == .answer ? "ANSWER" : "QUESTION")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if card.card.templateOrdinal > 0 {
                        Text("Card \(card.card.templateOrdinal + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                RenderedCardView(
                    face: SpeechRenderer().face(
                        card,
                        side: shownSide == .answer ? .answer : .question,
                        questionLocale: controller.questionLocale,
                        answerLocale: controller.answerLocale
                    ),
                    mediaDirectory: try? AppServices.mediaDirectory()
                )
                .id("\(card.id)-\(shownSide == .answer ? "a" : "q")")
                Text(shownSide == .answer ? "Tap to see the question" : "Tap to flip")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture { flipCard() }
            .onChange(of: controller.currentCard?.id) { _, _ in showingQuestion = false }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Double-tap to flip")
            .accessibilityAction(.default) { flipCard() }
        } else if controller.state == .idle {
            Text(controller.statusMessage ?? "Session unavailable")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    @ViewBuilder
    private var transcriptView: some View {
        if !controller.transcript.isEmpty, controller.voiceAvailable {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.orange)
                Text("“\(controller.transcript)”")
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.horizontal)
            .accessibilityLabel("Heard: \(controller.transcript)")
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 14) {
            Text("\(controller.reviewsThisSession)")
                .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
            Text(controller.reviewsThisSession == 1 ? "card reviewed" : "cards reviewed")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                summaryStat("\(controller.voiceReviews)", "by voice", "waveform")
                summaryStat("\(controller.touchReviews)", "by touch", "hand.tap")
                if let started = controller.startedAt {
                    summaryStat(durationText(Date().timeIntervalSince(started)), "minutes", "clock")
                }
            }
            if controller.completedWithoutTouch {
                Label("Entirely hands-free", systemImage: "figure.walk")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }
            if case .scheduled = controller.gather {
                Button {
                    Task { await controller.keepStudying() }
                } label: {
                    Label("Keep studying", systemImage: "forward.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if !controller.sessionLog.isEmpty {
                Divider().padding(.vertical, 4)
                VStack(spacing: 8) {
                    ForEach(controller.sessionLog.suffix(8).reversed()) { entry in
                        HStack {
                            Text(CardText.plain(entry.cardFront))
                                .lineLimit(1)
                                .font(.callout)
                            Spacer()
                            Text(entry.rating.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(entry.rating.tint)
                            Text(entry.intervalDays == 0 ? "today" : "\(entry.intervalDays)d")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal)
    }

    private func summaryStat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 1 ? "<1" : "\(minutes)"
    }

    private var shownSide: StudySessionController.Side {
        if showingQuestion { return .question }
        switch controller.state {
        case .speakingAnswer, .awaitingRating: return .answer
        default: return .question
        }
    }

    /// Flip while the card is being read. On the question that reveals the
    /// answer and stops the reading; on the answer it just shows the front.
    private func flipCard() {
        switch controller.state {
        case .speakingPrompt, .awaitingAnswer, .answerInProgress, .answerComplete:
            showingQuestion = false
            Task { await controller.reveal(mode: .touch) }
        case .speakingAnswer, .awaitingRating:
            showingQuestion.toggle()
        default:
            break
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            switch controller.state {
            case .awaitingRating:
                ratingButtons
                secondaryRow
            case .finished:
                Button {
                    onExit()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            default:
                primaryButton
                secondaryRow
            }
        }
        .padding()
        .background(.bar)
    }

    private var visibleRatings: [Rating] {
        controller.settings.simplifiedRatings ? [.again, .good] : [.again, .hard, .good, .easy]
    }

    /// Equal-width columns: an HStack would hand the button with the longest
    /// caption more room, which made Hard visibly wider than the others.
    private var ratingButtons: some View {
        let ratings = visibleRatings
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: ratings.count), spacing: 8) {
            ForEach(ratings) { rating in
                ratingButton(rating)
            }
        }
    }

    private func ratingButton(_ rating: Rating) -> some View {
        Button {
            Task { await controller.rate(rating, mode: .touch) }
        } label: {
            VStack(spacing: 2) {
                Text(rating.title)
                    .font(.headline)
                Text(rating.shortDescription)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(rating.tint)
        .accessibilityLabel("\(rating.title) — \(rating.spokenDescription)")
        .accessibilityIdentifier("session.rate.\(rating.title.lowercased())")
    }

    /// Whether the big button is Pause (so the secondary row hides its own).
    private var primaryIsPause: Bool {
        switch controller.state {
        case .paused, .speakingPrompt, .awaitingAnswer, .answerInProgress, .answerComplete, .awaitingRating:
            return false
        default: return true
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch controller.state {
        case .paused:
            bigButton("Resume", system: "play.fill") {
                Task { await controller.resume(mode: .touch) }
            }
            .accessibilityIdentifier("session.resume")
        case .speakingPrompt, .awaitingAnswer, .answerInProgress, .answerComplete:
            bigButton("Reveal answer", system: "lightbulb.fill") {
                Task { await controller.reveal(mode: .touch) }
            }
            .accessibilityIdentifier("session.reveal")
        default:
            bigButton("Pause", system: "pause.fill") {
                Task { await controller.pause(mode: .touch) }
            }
            .disabled(controller.state == .idle || controller.state == .loadingCard)
            .accessibilityIdentifier("session.pause")
        }
    }

    private func bigButton(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var secondaryRow: some View {
        HStack(spacing: 8) {
            if !primaryIsPause, controller.state != .paused {
                iconButton("Pause", system: "pause.fill") {
                    Task { await controller.pause(mode: .touch) }
                }
            }
            iconButton("Repeat", system: "arrow.counterclockwise") {
                Task { await controller.repeatSpoken(side: shownSide == .answer ? .answer : .question, mode: .touch) }
            }
            iconButton("Undo", system: "arrow.uturn.backward") {
                Task { await controller.undo(mode: .touch) }
            }
            .disabled(controller.reviewsThisSession == 0)
            iconButton("Skip", system: "forward.fill") {
                Task { await controller.skip(mode: .touch) }
            }
        }
        .disabled(controller.state == .idle)
    }

    private func iconButton(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: system)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
    }
}

// MARK: - Helpers

/// Soft pulsing halo behind the status orb while the app speaks or listens.
private struct PulsingRing: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(expanded ? 0 : 0.5), lineWidth: 3)
            .frame(width: expanded ? 96 : 72, height: expanded ? 96 : 72)
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

extension Rating {
    var tint: Color {
        switch self {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }
}

/// Card text for the session screen; audio-only sides get a placeholder.
enum CardText {
    static func plain(_ html: String) -> String {
        let text = HTMLText.plain(html)
        return text.isEmpty ? "(audio only)" : text
    }
}
