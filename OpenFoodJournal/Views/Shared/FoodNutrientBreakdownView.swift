// Nutrient-contribution drill-down retains the selected historical date.
import SwiftUI

struct FoodNutrientBreakdownView: View {
    @Environment(UserGoals.self) private var goals
    let foodName: String
    let period: NutritionStore.TimePeriod
    var referenceDate: Date = .now
    private var days: Int { NutritionDateRange.count(period) }

    var body: some View {
        NutritionLogQuery(from: NutritionDateRange.start(ending: referenceDate, days: days),
                          through: referenceDate) { analytics in
            let foodEntries = analytics.entriesByDate.values.flatMap { $0 }.filter { $0.name == foodName }
            let recordedIDs = Set(foodEntries.flatMap { NutritionAnalytics.micros(in: $0).map { $0.0.id } })
            List {
                Section {
                    Text(NutritionDateRange.label(ending: referenceDate, days: days)).foregroundStyle(.secondary)
                }
                Section("Macros") {
                    ForEach(NutritionMetric.macros(goals: goals)) { metric in
                        NutritionProgressRow(metric: metric, value: foodEntries.isEmpty ? nil : contribution(metric, analytics: analytics))
                    }
                }
                Section("Recorded micronutrients") {
                    ForEach(analytics.trackedMicros.filter { recordedIDs.contains($0.id) }) { metric in
                        NutritionProgressRow(metric: metric, value: contribution(metric, analytics: analytics))
                    }
                }
                Section { NutritionCitation() }
            }.listStyle(.insetGrouped)
        }.navigationTitle(foodName)
    }

    // Use the parent nutrient's recorded-day denominator, not only days on
    // which this food was eaten, so drilling down cannot change the average.
    private func contribution(_ metric: NutritionMetric, analytics: NutritionAnalytics) -> Double {
        analytics.contributions(metric, ending: referenceDate, days: days).first { $0.foodName == foodName }?.value ?? 0
    }
}
