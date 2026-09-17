import SwiftUI
import Charts

/// Progress dashboard (PRD §31): Today, History, Hands-Free, Collection.
struct StatsView: View {
    @Environment(AppServices.self) private var services
    @State private var today: StatsStore.TodayStats = .init()
    @State private var days: [StatsStore.DayStats] = []
    @State private var streak = 0
    @State private var collection: StatsStore.CollectionStats = .init()
    @State private var handsFree: StatsStore.HandsFreeStats = .init()
    @State private var range: HistoryRange = .month

    enum HistoryRange: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .week: return "7 days"
            case .month: return "30 days"
            case .quarter: return "90 days"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                todaySection
                historySection
                handsFreeSection
                collectionSection
            }
            .navigationTitle("Stats")
            .task { await load() }
            .refreshable { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .ankivoiceLibraryDidChange)) { _ in
                Task { await load() }
            }
        }
    }

    // MARK: Sections

    private var todaySection: some View {
        Section {
            HStack(spacing: 12) {
                heroStat(value: "\(today.reviews)", label: "reviews", icon: "checkmark.circle.fill", tint: .green)
                heroStat(value: durationText(today.studySeconds), label: "studied", icon: "clock.fill", tint: .blue)
                heroStat(value: "\(streak)", label: "day streak", icon: "flame.fill", tint: .orange)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)

            if today.reviews > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ratings today")
                        .font(.subheadline.weight(.semibold))
                    ratingDistribution
                    HStack(spacing: 8) {
                        ratingBar("Again", today.again, color: .red)
                        ratingBar("Hard", today.hard, color: .orange)
                        ratingBar("Good", today.good, color: .green)
                        ratingBar("Easy", today.easy, color: .blue)
                    }
                }
                .padding(.vertical, 4)
                statRow("New cards learned", "\(today.newCards)")
                statRow("Review cards completed", "\(today.reviewCards)")
            } else {
                Label("No reviews yet today. Start a deck to get going.", systemImage: "waveform")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        } header: {
            Text("Today")
        }
    }

    private var historySection: some View {
        Section {
            if days.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "chart.bar",
                    description: Text("Your daily review counts and retention will appear here after your first session.")
                )
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } else {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                let window = visibleDays
                Chart(window) { day in
                    BarMark(
                        x: .value("Date", day.day, unit: .day),
                        y: .value("Reviews", day.reviews)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                }
                .chartYAxisLabel("Reviews")
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 5)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 180)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))

                let totalReviews = window.reduce(0) { $0 + $1.reviews }
                let totalCorrect = window.reduce(0) { $0 + $1.correct }
                let activeDays = window.filter { $0.reviews > 0 }.count
                statRow("Reviews", totalReviews.formatted())
                if totalReviews > 0 {
                    statRow("Retention", percent(totalCorrect, of: totalReviews))
                }
                statRow("Days studied", "\(activeDays) of \(range.rawValue)")
                if activeDays > 0 {
                    statRow("Average per study day", (totalReviews / activeDays).formatted())
                }
            }
        } header: {
            Text("History")
        }
    }

    private var handsFreeSection: some View {
        Section {
            statRow("Hands-free reviews", handsFree.reviews.formatted())
            statRow("Hands-free time", durationText(handsFree.seconds))
            if today.reviews > 0 {
                statRow("Touch-free share today", percent(today.handsFreeReviews, of: today.reviews))
            }
        } header: {
            Text("Hands-free")
        } footer: {
            Text("A review counts as hands-free when it was rated by voice without touching the screen.")
        }
    }

    private var collectionSection: some View {
        Section("Collection") {
            statRow("Total cards", collection.totalCards.formatted())
            statRow("Mature cards (21d+)", collection.matureCards.formatted())
            statRow("Suspended", collection.suspendedCards.formatted())
        }
    }

    // MARK: Data

    private var visibleDays: [StatsStore.DayStats] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: Date()) ?? Date())
        return days.filter { $0.day >= start }
    }

    private func load() async {
        today = (try? services.stats.today()) ?? .init()
        days = (try? services.stats.history(days: 365)) ?? []
        streak = (try? services.stats.streak()) ?? 0
        collection = (try? services.stats.collectionStats()) ?? .init()
        handsFree = (try? services.stats.handsFree()) ?? .init()
    }

    // MARK: Pieces

    private func heroStat(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private struct RatingSlice: Identifiable {
        let id: String
        let count: Int
        let color: Color
    }

    private var ratingDistribution: some View {
        let slices = [
            RatingSlice(id: "again", count: today.again, color: .red),
            RatingSlice(id: "hard", count: today.hard, color: .orange),
            RatingSlice(id: "good", count: today.good, color: .green),
            RatingSlice(id: "easy", count: today.easy, color: .blue),
        ].filter { $0.count > 0 }
        let total = max(1, slices.reduce(0) { $0 + $1.count })
        return GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(slices) { slice in
                    slice.color.frame(width: max(2, proxy.size.width * CGFloat(slice.count) / CGFloat(total)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func ratingBar(_ label: String, _ count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.headline.monospacedDigit())
            Text(label).font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "—" }
        return String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }

    private func durationText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return String(format: "%.1fh", Double(seconds) / 3600)
    }
}
