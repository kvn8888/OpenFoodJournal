// Reviewed Nutrition concept, backed by date-scoped live SwiftData queries.
import SwiftUI

struct NutritionDetailView: View {
    @Environment(UserGoals.self) private var goals
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPeriod: NutritionStore.TimePeriod = .daily
    @State private var selectedDate: Date
    @State private var showUncommon = false
    @State private var selectedMetric: NutritionMetric?

    init(referenceDate: Date = .now) {
        _selectedDate = State(initialValue: Calendar.current.startOfDay(for: referenceDate))
    }
    private var days: Int { NutritionDateRange.count(selectedPeriod) }

    var body: some View {
        NutritionLogQuery(from: NutritionDateRange.start(ending: selectedDate, days: days), through: selectedDate) { analytics in
            let macros = NutritionMetric.macros(goals: goals)
            let calories = macros[0]
            let calorieAverage = NutritionAnalytics.average(analytics.series(calories, ending: selectedDate, days: days))
            let progress = calories.goal > 0 ? (calorieAverage ?? 0) / calories.goal : 0
            let unknown = analytics.trackedMicros.filter { $0.id.hasPrefix("custom:") }
            ScrollView {
                // Lazy: the page carries up to 37 nutrient rows behind glass
                // surfaces once "More Nutrients" is open. The List this replaced
                // realized rows on demand; a plain VStack would not.
                LazyVStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Period", selection: $selectedPeriod) {
                            Text("Day").tag(NutritionStore.TimePeriod.daily)
                            Text("Week").tag(NutritionStore.TimePeriod.weekly)
                            Text("Month").tag(NutritionStore.TimePeriod.monthly)
                        }.pickerStyle(.segmented)
                        let label = NutritionDateRange.label(ending: selectedDate, days: days)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                            .ofjNumericTextTransition(value: selectedDate.timeIntervalSinceReferenceDate, trigger: label)
                    }

                    NutritionSummaryCard(analytics: analytics, metrics: macros,
                                         date: selectedDate, days: days) { selectedMetric = $0 }

                    ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                        let nutrients = KnownMicronutrients.common.filter { $0.category == category }
                        if !nutrients.isEmpty {
                            nutrientSection(category.rawValue,
                                            metrics: nutrients.map { NutritionMetric.known($0, overrides: goals.micronutrientOverrides) },
                                            analytics: analytics)
                        }
                    }

                    DisclosureGroup("More Nutrients", isExpanded: $showUncommon) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                                let nutrients = KnownMicronutrients.uncommon.filter { $0.category == category }
                                if !nutrients.isEmpty {
                                    Text(category.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    ForEach(nutrients) { known in
                                        nutrientRow(.known(known, overrides: goals.micronutrientOverrides), analytics: analytics)
                                    }
                                }
                            }
                        }.padding(.top, 12)
                    }
                    .padding(16)
                    .modifier(NutritionSurface())

                    if !unknown.isEmpty {
                        nutrientSection("Other nutrients", metrics: unknown, analytics: analytics)
                    }

                    NutritionCitation()
                }
                .padding(16)
            }
            .background { JournalCalorieBackground(state: OFJColor.journalCalorieState(for: progress)) }
        }
        .navigationTitle("Nutrition")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Label("Journal", systemImage: "chevron.left") }
                    .labelStyle(.titleAndIcon)
            }
            NutritionRangeArrows(date: $selectedDate, days: days)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationDestination(item: $selectedMetric) { metric in
            NutritionNutrientDetailView(metric: metric, referenceDate: selectedDate, period: selectedPeriod)
        }
    }

    @ViewBuilder
    private func nutrientSection(_ title: String, metrics: [NutritionMetric], analytics: NutritionAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            VStack(spacing: 12) {
                ForEach(metrics) { nutrientRow($0, analytics: analytics) }
            }
            .padding(16)
            .modifier(NutritionSurface())
        }
    }

    private func nutrientRow(_ metric: NutritionMetric, analytics: NutritionAnalytics) -> some View {
        Button { selectedMetric = metric } label: {
            HStack {
                NutritionProgressRow(metric: metric, value: NutritionAnalytics.average(analytics.series(metric, ending: selectedDate, days: days)))
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }.contentShape(.rect)
        }.buttonStyle(.plain)
    }
}
