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
            List {
                Section {
                    Picker("Period", selection: $selectedPeriod) {
                        Text("Day").tag(NutritionStore.TimePeriod.daily)
                        Text("Week").tag(NutritionStore.TimePeriod.weekly)
                        Text("Month").tag(NutritionStore.TimePeriod.monthly)
                    }.pickerStyle(.segmented)
                    Text(NutritionDateRange.label(ending: selectedDate, days: days))
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)

                Section {
                    NutritionSummaryCard(analytics: analytics, metrics: NutritionMetric.macros(goals: goals),
                                         date: selectedDate, days: days) { selectedMetric = $0 }
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                    Section(category.rawValue) {
                        ForEach(KnownMicronutrients.common.filter { $0.category == category }) { known in
                            nutrientRow(.known(known), analytics: analytics)
                        }
                    }
                }

                Section {
                    DisclosureGroup("More Nutrients", isExpanded: $showUncommon) {
                        ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                            Text(category.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(KnownMicronutrients.uncommon.filter { $0.category == category }) { known in
                                nutrientRow(.known(known), analytics: analytics)
                            }
                        }
                    }
                }

                let unknown = analytics.trackedMicros.filter { $0.id.hasPrefix("custom:") }
                if !unknown.isEmpty {
                    Section("Other nutrients") { ForEach(unknown) { nutrientRow($0, analytics: analytics) } }
                }
                Section { NutritionCitation().listRowBackground(Color.clear) }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Nutrition")
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Label("Journal", systemImage: "chevron.left") }
            }
            NutritionRangeArrows(date: $selectedDate, days: days)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationDestination(item: $selectedMetric) { metric in
            NutritionNutrientDetailView(metric: metric, referenceDate: selectedDate, period: selectedPeriod)
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
