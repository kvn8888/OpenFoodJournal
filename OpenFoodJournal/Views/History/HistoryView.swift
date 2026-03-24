// OpenFoodJournal — HistoryView
// Calendar date picker, week-over-week macro comparison, and inline day detail.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    @State private var selectedDate: Date = .now

    // Current selected day's log
    private var selectedLog: DailyLog? {
        nutritionStore.fetchLog(for: selectedDate)
    }

    // MARK: - Week-over-week data

    private var thisWeekLogs: [DailyLog] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6, to: .now)!
        return nutritionStore.fetchLogs(from: start, to: .now)
    }

    private var lastWeekLogs: [DailyLog] {
        let calendar = Calendar.current
        let thisWeekStart = calendar.date(byAdding: .day, value: -6, to: .now)!
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart)!
        let lastWeekEnd = calendar.date(byAdding: .day, value: -1, to: thisWeekStart)!
        return nutritionStore.fetchLogs(from: lastWeekStart, to: lastWeekEnd)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Calendar with calorie progress rings on each day
                    CalendarGridView(selectedDate: $selectedDate)

                    // Week-over-week macro comparison
                    weekComparisonSection

                    // Chart for this week
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This Week")
                            .font(.headline)
                            .padding(.horizontal)

                        if thisWeekLogs.isEmpty {
                            Text("No data yet — start logging meals!")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                                .glassEffect(in: .rect(cornerRadius: 16))
                                .padding(.horizontal)
                        } else {
                            MacroChartView(logs: thisWeekLogs, goals: goals)
                                .padding(.horizontal)
                        }
                    }

                    // Inline day detail for selected date
                    inlineDayDetail

                    Color.clear.frame(height: 24)
                }
                .padding(.vertical)
            }
            .navigationTitle("History")
        }
    }

    // MARK: - Week-over-Week Comparison

    private var weekComparisonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last Week vs This Week")
                .font(.headline)
                .padding(.horizontal)

            // Each macro card navigates to the NutritionDetailView
            NavigationLink {
                NutritionDetailView()
            } label: {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    comparisonCard("Calories", thisWeek: avgMacro(\.totalCalories, logs: thisWeekLogs), lastWeek: avgMacro(\.totalCalories, logs: lastWeekLogs), unit: "kcal", color: .orange)
                    comparisonCard("Protein", thisWeek: avgMacro(\.totalProtein, logs: thisWeekLogs), lastWeek: avgMacro(\.totalProtein, logs: lastWeekLogs), unit: "g", color: .blue)
                    comparisonCard("Carbs", thisWeek: avgMacro(\.totalCarbs, logs: thisWeekLogs), lastWeek: avgMacro(\.totalCarbs, logs: lastWeekLogs), unit: "g", color: .green)
                    comparisonCard("Fat", thisWeek: avgMacro(\.totalFat, logs: thisWeekLogs), lastWeek: avgMacro(\.totalFat, logs: lastWeekLogs), unit: "g", color: .yellow)                }
                .padding(.horizontal)
            }
            .buttonStyle(.plain)
        }
    }

    private func avgMacro(_ keyPath: KeyPath<DailyLog, Double>, logs: [DailyLog]) -> Double {
        guard !logs.isEmpty else { return 0 }
        return logs.map { $0[keyPath: keyPath] }.reduce(0, +) / 7.0
    }

    private func comparisonCard(_ name: String, thisWeek: Double, lastWeek: Double, unit: String, color: Color) -> some View {
        let delta = lastWeek > 0 ? ((thisWeek - lastWeek) / lastWeek) * 100 : 0
        let deltaSign = delta >= 0 ? "+" : ""

        return VStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(Int(thisWeek))")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(color)

            Text("\(unit)/day avg")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if lastWeek > 0 {
                Text("\(deltaSign)\(Int(delta))%")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(abs(delta) < 10 ? Color.secondary : (delta > 0 ? Color.orange : Color.green))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    // MARK: - Inline Day Detail

    private var inlineDayDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Date header with macro summary
            HStack {
                Text(selectedDate, style: .date)
                    .font(.headline)
                Spacer()
                if let log = selectedLog {
                    Text("\(Int(log.totalCalories)) kcal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            if let log = selectedLog {
                MacroSummaryBar(log: log, goals: goals)
                    .padding(.horizontal)

                if !log.entries.isEmpty {
                    // Entries grouped by meal — using LazyVStack for non-List context
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(MealType.allCases) { mealType in
                            let entries = log.entries(for: mealType)
                            if !entries.isEmpty {
                                Section {
                                    ForEach(entries) { entry in
                                        EntryRowView(entry: entry, onDelete: {
                                            nutritionStore.delete(entry)
                                        })
                                        .padding(.horizontal)
                                    }
                                } header: {
                                    HStack {
                                        Label(mealType.rawValue, systemImage: mealType.systemImage)
                                            .font(.footnote)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(Int(entries.reduce(0) { $0 + $1.calories })) kcal")
                                            .font(.footnote)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Nothing logged this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
        .padding(.vertical, 12)
        .glassEffect(in: .rect(cornerRadius: 16))
        .padding(.horizontal)
    }
}

// MARK: - DayDetailView (kept for backward compat if navigated to directly)

struct DayDetailView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals
    let date: Date

    private var log: DailyLog? {
        nutritionStore.fetchLog(for: date)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                MacroSummaryBar(log: log, goals: goals)
                    .padding(.horizontal)

                if let log, !log.entries.isEmpty {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(MealType.allCases) { mealType in
                            MealSectionView(
                                mealType: mealType,
                                entries: log.entries(for: mealType),
                                onSelect: { _ in },
                                onDelete: { entry in nutritionStore.delete(entry) }
                            )
                        }
                    }
                    .padding(.horizontal)
                } else {
                    Text("Nothing logged this day.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(date.formatted(date: .long, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    HistoryView()
        .modelContainer(ModelContainer.preview)
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(UserGoals())
}
