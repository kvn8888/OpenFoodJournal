// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    @State private var selectedDate: Date = .now
    @State private var path = NavigationPath()

    private var weekLogs: [DailyLog] {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: .now)!
        return nutritionStore.fetchLogs(from: start, to: .now)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 20) {
                    // Calendar date picker
                    DatePicker(
                        "Select date",
                        selection: $selectedDate,
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding(.horizontal)
                    .glassEffect(in: .rect(cornerRadius: 20))
                    .padding(.horizontal)

                    // Weekly chart
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Past 7 Days")
                            .font(.headline)
                            .padding(.horizontal)

                        if weekLogs.isEmpty {
                            Text("No data yet — start logging meals!")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                                .glassEffect(in: .rect(cornerRadius: 16))
                                .padding(.horizontal)
                        } else {
                            MacroChartView(logs: weekLogs, goals: goals)
                                .padding(.horizontal)
                        }
                    }

                    // Tap-to-view selected day
                    NavigationLink(value: selectedDate) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedDate, style: .date)
                                    .font(.headline)
                                let log = nutritionStore.fetchLog(for: selectedDate)
                                if let log {
                                    Text("\(Int(log.totalCalories)) kcal · \(log.entries.count) items")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("No entries")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                        .padding(.horizontal)
                    }
                    .buttonStyle(.plain)

                    Color.clear.frame(height: 24)
                }
                .padding(.vertical)
            }
            .navigationTitle("History")
            .navigationDestination(for: Date.self) { date in
                DayDetailView(date: date)
            }
        }
    }
}

// MARK: - DayDetailView

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
