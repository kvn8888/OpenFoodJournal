// Reviewed History hierarchy with live query-backed calendar, trends and day detail.
import SwiftUI

struct HistoryView: View {
    @Environment(UserGoals.self) private var goals
    @State private var selectedDate = Calendar.current.startOfDay(for: Date.now)
    @State private var comparisonDate = Calendar.current.startOfDay(for: Date.now)
    @State private var monthly = false
    @State private var selectedMetricID = "macro:calories"
    @State private var showDetail = false
    private var days: Int { monthly ? 30 : 7 }
    private var oldestDate: Date {
        let month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        return Calendar.current.date(byAdding: .month, value: -26, to: month) ?? month
    }

    var body: some View {
        NavigationStack {
            NutritionLogQuery(from: min(oldestDate, NutritionDateRange.offset(comparisonDate, days: -60)), through: .now) { analytics in
                let macros = NutritionMetric.macros(goals: goals)
                let metric = (macros + analytics.trackedMicros).first { $0.id == selectedMetricID } ?? macros[0]
                let selectedCalories = analytics.valuesByDate[Calendar.current.startOfDay(for: selectedDate)]?["macro:calories"]
                let progress = goals.dailyCalories > 0 ? (selectedCalories ?? 0) / goals.dailyCalories : 0
                ScrollView {
                    VStack(spacing: 20) {
                        CalendarGridView(selectedDate: $selectedDate, calorieProgressByDate: analytics.valuesByDate.mapValues {
                            goals.dailyCalories > 0 ? ($0["macro:calories"] ?? 0) / goals.dailyCalories : 0
                        })
                        Button { showDetail = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    let dayLabel = selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                                    Text(dayLabel)
                                        .font(.headline)
                                        .ofjNumericTextTransition(value: selectedDate.timeIntervalSinceReferenceDate, trigger: dayLabel)
                                    let caption = selectedCalories.map {
                                        "\(NutritionFormat.number($0)) kcal · \(Int((progress * 100).rounded()))% of goal · \(analytics.entries(on: selectedDate).count) entries"
                                    } ?? "No entries recorded"
                                    Text(caption)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .ofjNumericTextTransition(value: selectedCalories ?? 0, trigger: caption)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(16).contentShape(.rect)
                        }.buttonStyle(.plain).modifier(NutritionSurface()).padding(.horizontal, 16)

                        Picker("Date range", selection: $monthly) {
                            Text("Week").tag(false)
                            Text("Month").tag(true)
                        }.pickerStyle(.segmented).padding(.horizontal, 16)

                        VStack(alignment: .leading, spacing: 16) {
                            NutritionRangeControl(date: $comparisonDate, days: days)
                            NutritionMetricPicker(macros: macros, micros: analytics.trackedMicros, selectedID: $selectedMetricID)
                            NutritionTrendCard(analytics: analytics, metric: metric, date: comparisonDate, days: days, comparePrevious: true)
                        }.padding(16).modifier(NutritionSurface()).padding(.horizontal, 16)
                    }.padding(.vertical, 16)
                }
                .background { JournalCalorieBackground(state: OFJColor.journalCalorieState(for: progress)) }
            }
            .navigationTitle("History")
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationDestination(isPresented: $showDetail) {
                DayDetailView(date: selectedDate) { selectedDate = $0 }
            }
            .onChange(of: selectedDate) { _, date in comparisonDate = date }
        }
    }
}

struct DayDetailView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals
    @State private var selectedDate: Date
    @State private var editingEntry: NutritionEntry?
    @State private var showMicros = false
    let onDateChange: (Date) -> Void

    init(date: Date, onDateChange: @escaping (Date) -> Void = { _ in }) {
        _selectedDate = State(initialValue: Calendar.current.startOfDay(for: date))
        self.onDateChange = onDateChange
    }

    var body: some View {
        NutritionLogQuery(from: selectedDate, through: selectedDate) { analytics in
            let macros = NutritionMetric.macros(goals: goals)
            let entries = analytics.entries(on: selectedDate)
            let values = analytics.valuesByDate[Calendar.current.startOfDay(for: selectedDate)] ?? [:]
            let calories = values["macro:calories"]
            let progress = goals.dailyCalories > 0 ? (calories ?? 0) / goals.dailyCalories : 0
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(calories.map(NutritionFormat.number) ?? "—").font(.system(size: 32, weight: .bold, design: .rounded))
                                .ofjNumericTextTransition(value: calories ?? 0)
                            Text("/ \(NutritionFormat.number(goals.dailyCalories)) kcal").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let calories, goals.dailyCalories > 0 {
                            Text("\(NutritionFormat.number(abs(goals.dailyCalories - calories))) kcal \(calories > goals.dailyCalories ? "above goal" : "remaining")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(macros + analytics.trackedMicros.filter { ["fiber", "sodium", "added_sugars"].contains($0.id) }) { metric in
                            NutritionProgressRow(metric: metric, value: values[metric.id])
                        }
                    }.padding(18).modifier(NutritionSurface())

                    if !analytics.trackedMicros.isEmpty {
                        DisclosureGroup("Micronutrients (\(analytics.trackedMicros.count))", isExpanded: $showMicros) {
                            VStack(spacing: 12) {
                                ForEach(analytics.trackedMicros) { metric in
                                    NavigationLink {
                                        NutritionNutrientDetailView(metric: metric, referenceDate: selectedDate, period: .daily)
                                    } label: {
                                        HStack {
                                            NutritionProgressRow(metric: metric, value: values[metric.id])
                                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                        }.contentShape(.rect)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.top, 12)
                        }.padding(16).modifier(NutritionSurface())
                    }

                    ForEach(MealType.allCases) { meal in
                        let mealEntries = entries.filter { $0.mealType == meal }.sorted { $0.timestamp < $1.timestamp }
                        if !mealEntries.isEmpty {
                            VStack(spacing: 0) {
                                HStack {
                                    Label(meal.rawValue, systemImage: meal.systemImage).font(.headline)
                                    Spacer()
                                    Text("\(NutritionFormat.number(mealEntries.reduce(0) { $0 + $1.calories })) kcal").font(.subheadline)
                                }.foregroundStyle(.secondary).padding(.vertical, 12)
                                ForEach(mealEntries) { entry in
                                    JournalEntryButton(entry: entry,
                                                       onSelect: { editingEntry = $0 },
                                                       onDelete: { nutritionStore.delete($0) })
                                    Divider()
                                }
                            }
                            // No solid row fill or full-meal material over the page
                            // gradient. The shared macro pills retain their own glass.
                        }
                    }
                    if entries.isEmpty { Text("No meals recorded for this date.").foregroundStyle(.secondary) }
                }.padding(16)
            }
            .background { JournalCalorieBackground(state: OFJColor.journalCalorieState(for: progress)) }
        }
        .navigationTitle(selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
        .navigationBarTitleDisplayMode(.large)
        .toolbar { NutritionRangeArrows(date: $selectedDate, days: 1) }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .sheet(item: $editingEntry) { EditEntryView(entry: $0) }
        .onChange(of: selectedDate) { _, date in onDateChange(date) }
    }
}
