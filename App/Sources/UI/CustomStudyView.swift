import SwiftUI

/// Anki's custom-study presets. Each one rebuilds a filtered deck and the
/// caller studies it. Limits are ignored on purpose: this is how you keep
/// going after the day's queue is done.
struct CustomStudyView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let deckName: String
    let onStart: (Int64) -> Void

    @State private var extraNew = 10
    @State private var extraReviews = 20
    @State private var aheadDays = 1
    @State private var aheadLimit = 20
    @State private var tag = ""
    @State private var tagLimit = 50
    @State private var previewLimit = 20
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preset("More new cards", system: "plus.square") {
                        extraNew
                    } stepper: {
                        Stepper("Cards", value: $extraNew, in: 1...500)
                    } start: {
                        start(query: "deck:\(quoted(deckName)) is:new", limit: extraNew, order: .added, reschedule: true)
                    }
                    preset("More review cards", system: "arrow.clockwise") {
                        extraReviews
                    } stepper: {
                        Stepper("Cards", value: $extraReviews, in: 1...999)
                    } start: {
                        start(query: "deck:\(quoted(deckName)) is:due", limit: extraReviews, order: .due, reschedule: true)
                    }
                } header: {
                    Text("Today's limits")
                } footer: {
                    Text("The normal study button stops at the daily caps. These gather more cards right now.")
                }

                Section("Review ahead") {
                    Stepper("Days ahead: \(aheadDays)", value: $aheadDays, in: 1...30)
                    Stepper("Cards: \(aheadLimit)", value: $aheadLimit, in: 1...999)
                    Button {
                        start(query: "deck:\(quoted(deckName)) is:review", limit: aheadLimit, order: .due, reschedule: true)
                    } label: {
                        Label("Study cards due in the next \(aheadDays) day\(aheadDays == 1 ? "" : "s")", systemImage: "calendar")
                    }
                }

                Section("Focus") {
                    Button {
                        start(query: "deck:\(quoted(deckName)) rated:1:1", limit: 200, order: .due, reschedule: true)
                    } label: {
                        Label("Study cards forgotten today", systemImage: "exclamationmark.arrow.circlepath")
                    }
                    TextField("Tag", text: $tag)
                        .autocorrectionDisabled()
                    Stepper("Cards: \(tagLimit)", value: $tagLimit, in: 1...999)
                    Button {
                        start(query: "deck:\(quoted(deckName)) tag:\(tag)", limit: tagLimit, order: .due, reschedule: true)
                    } label: {
                        Label("Study this tag", systemImage: "tag")
                    }
                    .disabled(tag.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section {
                    Stepper("Cards: \(previewLimit)", value: $previewLimit, in: 1...200)
                    Button {
                        start(query: "deck:\(quoted(deckName)) is:new", limit: previewLimit, order: .added, reschedule: false)
                    } label: {
                        Label("Preview new cards", systemImage: "eye")
                    }
                } footer: {
                    Text("Preview does not change scheduling. The other actions do.")
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Custom Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func quoted(_ name: String) -> String {
        name.contains(" ") ? "\"\(name)\"" : name
    }

    @ViewBuilder
    private func preset<Stepper: View>(
        _ title: String, system: String, count: () -> Int,
        @ViewBuilder stepper: () -> Stepper, start action: @escaping () -> Void
    ) -> some View {
        stepper()
        Button(action: action) {
            Label("\(title) (\(count()))", systemImage: system)
        }
    }

    private func start(query: String, limit: Int, order: FilteredDeckBuilder.Order, reschedule: Bool) {
        let builder = FilteredDeckBuilder(decks: services.decks, cards: services.cards, reviews: services.reviews)
        // Review-ahead has to exclude cards due after the window. The query
        // language has no date range, so gather due-ordered and the builder
        // limit, then drop anything past the horizon before placing... 
        // `is:review` plus due order takes the soonest, which is the horizon
        // when `limit` is the number of cards rather than days. For a day
        // horizon, filter after the match.
        do {
            var search = query
            if aheadDays > 0, query.contains("is:review") {
                search = query
            }
            let deck = try builder.rebuild(
                named: "Custom Study Session", query: search, limit: limit,
                order: order, reschedule: reschedule
            )
            if query.contains("is:review"), aheadDays > 0 {
                try trimAhead(deckID: deck.id)
            }
            NotificationCenter.default.post(name: .ankivoiceLibraryDidChange, object: nil)
            onStart(deck.id)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Custom study "review ahead" only wants cards due within `aheadDays`.
    private func trimAhead(deckID: Int64) throws {
        let horizon = Date().addingTimeInterval(Double(aheadDays) * 86_400)
        let sitting = try services.cards.cards(inDeck: deckID)
        for card in sitting where card.scheduling.due > horizon {
            try services.cards.returnFromFiltered(card.id)
        }
    }
}
