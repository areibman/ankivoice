import SwiftUI
import Charts

/// Forecast, calendar, intervals, hourly, buttons, card types, added,
/// true retention, and FSRS distributions. Overview stays in `StatsView`.
struct AnkiGraphSections: View {
    let graphs: AnkiGraphs

    var body: some View {
        Group {
            barSection("Forecast", "Cards due", graphs.forecast, caption: "Scheduled reviews and learning cards for the next 30 days. New cards are not included.")
            calendarSection
            barSection("Intervals", "Review cards", graphs.intervals, caption: "Stability of review cards, in the buckets Anki's interval graph uses.")
            barSection("Hourly breakdown", "Reviews", graphs.hourly, caption: "Reviews by hour of day, all time.")
            barSection("Answer buttons", "Reviews", graphs.buttons, caption: "Every recorded grade, not just today.")
            barSection("Card types", "Cards", graphs.cardTypes, caption: "Young means a review card with stability under 21 days. Mature is 21 days or more.")
            barSection("Added", "Cards added", graphs.added, caption: "Cards created over the last 30 days.")
            retentionSection
            barSection("Stability", "Review cards", graphs.stability, caption: "FSRS stability of review cards.")
            barSection("Difficulty", "Review cards", graphs.difficulty, caption: "FSRS difficulty, 1 easy to 10 hard.")
            barSection("Retrievability", "Review cards", graphs.retrievability, caption: "Predicted recall right now, from current stability and time since the last review.")
        }
    }

    private var calendarSection: some View {
        Section {
            let maxCount = max(graphs.calendar.map(\.value).max() ?? 1, 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 17), spacing: 3) {
                ForEach(graphs.calendar) { day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(day.value == 0 ? 0.08 : 0.2 + 0.8 * Double(day.value) / Double(maxCount)))
                        .frame(height: 12)
                        .accessibilityLabel("\(day.label), \(day.value) reviews")
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Calendar")
        } footer: {
            Text("Reviews per day for the last 17 weeks. Darker means more reviews.")
        }
    }

    private var retentionSection: some View {
        Section {
            retentionRow("Young cards", graphs.youngRetention, pass: graphs.youngPass, fail: graphs.youngFail)
            retentionRow("Mature cards", graphs.matureRetention, pass: graphs.maturePass, fail: graphs.matureFail)
        } header: {
            Text("True retention")
        } footer: {
            Text("Share of review-card grades that were not Again. Young is stability under 21 days. This is not “percent of buttons that were Good”.")
        }
    }

    private func retentionRow(_ title: String, _ value: Double?, pass: Int, fail: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let value {
                Text(percent(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("\(pass + fail) reviews")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func barSection(_ title: String, _ series: String, _ buckets: [AnkiGraphs.Bucket], caption: String) -> some View {
        Section {
            if buckets.allSatisfy({ $0.value == 0 }) {
                Text("Nothing here yet.").foregroundStyle(.secondary)
            } else {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Bucket", bucket.label),
                        y: .value(series, bucket.value)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .chartYAxisLabel(series)
                .frame(height: 160)
            }
        } header: {
            Text(title)
        } footer: {
            Text(caption)
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
