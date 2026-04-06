// OpenFoodJournal — HistoryView
// Calendar date picker, week-over-week macro comparison, and inline day detail.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    @State private var selectedDate: Date = .now
    @State private var editingEntry: NutritionEntry?
    @State private var comparisonPeriod: ComparisonPeriod = .weekly
    @State private var comparisonDate: Date = .now

    private let calendar = Calendar.current

    /// Period options for the comparison section
    enum ComparisonPeriod: String, CaseIterable {
        case weekly = "Week"
        case monthly = "Month"
    }

    // Current selected day's log
    private var selectedLog: DailyLog? {
        nutritionStore.fetchLog(for: selectedDate)
    }

    // MARK: - Period-aware comparison data

    /// Number of days in the current comparison period
    private var periodDays: Int {
        comparisonPeriod == .weekly ? 7 : 30
    }

    /// Logs for the current period ending at comparisonDate
    private var currentPeriodLogs: [DailyLog] {
        let start = calendar.date(byAdding: .day, value: -(periodDays - 1), to: comparisonDate)!
        return nutritionStore.fetchLogs(from: start, to: comparisonDate)
    }

    /// Logs for the previous period (same length, immediately before current)
    private var previousPeriodLogs: [DailyLog] {
        let currentStart = calendar.date(byAdding: .day, value: -(periodDays - 1), to: comparisonDate)!
        let prevEnd = calendar.date(byAdding: .day, value: -1, to: currentStart)!
        let prevStart = calendar.date(byAdding: .day, value: -(periodDays - 1), to: prevEnd)!
        return nutritionStore.fetchLogs(from: prevStart, to: prevEnd)
    }

    /// Whether user can navigate forward (can't go past today)
    private var canGoForward: Bool {
        calendar.startOfDay(for: comparisonDate) < calendar.startOfDay(for: .now)
    }

    /// Formatted date label for the comparison period
    private var comparisonDateLabel: String {
        switch comparisonPeriod {
        case .weekly:
            let start = calendar.date(byAdding: .day, value: -6, to: comparisonDate)!
            let startStr = start.formatted(.dateTime.month(.abbreviated).day())
            let endStr = comparisonDate.formatted(.dateTime.month(.abbreviated).day())
            return "\(startStr) – \(endStr)"
        case .monthly:
            return comparisonDate.formatted(.dateTime.month(.wide).year())
        }
    }

    /// Label for current vs previous period
    private var comparisonTitle: String {
        comparisonPeriod == .weekly ? "Last Week vs This Week" : "Last Month vs This Month"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Calendar with calorie progress rings on each day
                    CalendarGridView(selectedDate: $selectedDate)

                    // Period picker + date nav + comparison
                    comparisonSection

                    // Chart for current period
                    VStack(alignment: .leading, spacing: 8) {
                        if currentPeriodLogs.isEmpty {
                            Text("No data yet — start logging meals!")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                                .glassEffect(in: .rect(cornerRadius: 16))
                                .padding(.horizontal)
                        } else {
                            MacroChartView(logs: currentPeriodLogs, goals: goals)
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
            .sheet(item: $editingEntry) { entry in
                EditEntryView(entry: entry)
            }
            .animation(.easeInOut(duration: 0.2), value: comparisonDate)
            .animation(.easeInOut(duration: 0.2), value: comparisonPeriod)
            .onChange(of: selectedDate) { _, newDate in
                withAnimation(.easeInOut(duration: 0.2)) {
                    comparisonDate = newDate
                }
            }
        }
    }

    // MARK: - Comparison Section

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Period picker
            Picker("Period", selection: $comparisonPeriod) {
                ForEach(ComparisonPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // Date navigation
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        navigateComparison(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glass)

                    Text(comparisonDateLabel)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassEffect(in: .capsule)
                        .contentTransition(.numericText())

                    Button {
                        navigateComparison(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glass)
                    .disabled(!canGoForward)
                    .opacity(canGoForward ? 1 : 0.3)
                }
            }
            .padding(.horizontal)

            Text(comparisonTitle)
                .font(.headline)
                .padding(.horizontal)

            // Macro comparison cards
            NavigationLink {
                NutritionDetailView()
            } label: {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    comparisonCard("Calories", current: avgMacro(\.totalCalories, logs: currentPeriodLogs), previous: avgMacro(\.totalCalories, logs: previousPeriodLogs), unit: "kcal", color: .orange)
                    comparisonCard("Protein", current: avgMacro(\.totalProtein, logs: currentPeriodLogs), previous: avgMacro(\.totalProtein, logs: previousPeriodLogs), unit: "g", color: .blue)
                    comparisonCard("Carbs", current: avgMacro(\.totalCarbs, logs: currentPeriodLogs), previous: avgMacro(\.totalCarbs, logs: previousPeriodLogs), unit: "g", color: .green)
                    comparisonCard("Fat", current: avgMacro(\.totalFat, logs: currentPeriodLogs), previous: avgMacro(\.totalFat, logs: previousPeriodLogs), unit: "g", color: Color(red: 0.9, green: 0.75, blue: 0.0))
                }
                .padding(.horizontal)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Navigation

    private func navigateComparison(by direction: Int) {
        let days = comparisonPeriod == .weekly ? 7 : 30
        guard let newDate = calendar.date(byAdding: .day, value: direction * days, to: comparisonDate) else { return }

        if direction > 0 && calendar.startOfDay(for: newDate) > calendar.startOfDay(for: .now) {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            comparisonDate = newDate
        }
    }

    private func avgMacro(_ keyPath: KeyPath<DailyLog, Double>, logs: [DailyLog]) -> Double {
        guard !logs.isEmpty else { return 0 }
        return logs.map { $0[keyPath: keyPath] }.reduce(0, +) / Double(periodDays)
    }

    private func comparisonCard(_ name: String, current: Double, previous: Double, unit: String, color: Color) -> some View {
        let delta = previous > 0 ? ((current - previous) / previous) * 100 : 0
        let deltaSign = delta >= 0 ? "+" : ""

        return VStack(spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(Int(current))")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(color)

            Text("\(unit)/day avg")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if previous > 0 {
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
                // No extra .padding(.horizontal) here — MacroSummaryBar has its own internal
                // padding and glass. The extra outer pad would crush the ring row and cause
                // overflow that widens the entire ScrollView content.
                MacroSummaryBar(log: log, goals: goals)

                if !log.safeEntries.isEmpty {
                    // Entries grouped by meal — using LazyVStack for non-List context
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(MealType.allCases) { mealType in
                            let entries = log.entries(for: mealType)
                            if !entries.isEmpty {
                                Section {
                                    ForEach(entries) { entry in
                                        Button {
                                            editingEntry = entry
                                        } label: {
                                            EntryRowView(entry: entry, onDelete: {
                                                nutritionStore.delete(entry)
                                            })
                                            .padding(.horizontal)
                                        }
                                        .buttonStyle(.plain)
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
                

                if let log, !log.safeEntries.isEmpty {
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
