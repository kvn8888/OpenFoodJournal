// OpenFoodJournal — NutrientBreakdownView
// Shows which foods contributed to a specific nutrient's intake,
// with a donut chart and per-food contribution bars.
// Supports both macronutrients (calories/protein/carbs/fat) and micronutrients.
// AGPL-3.0 License

import SwiftUI
import Charts

/// What kind of nutrient we're breaking down
enum NutrientKind {
    case micro(KnownMicronutrient)
    case macro(MacroType)

    enum MacroType: String {
        case calories = "Calories"
        case protein = "Protein"
        case carbs = "Carbs"
        case fat = "Fat"

        var unit: String {
            self == .calories ? "kcal" : "g"
        }

        /// Extracts the macro value from an entry
        func value(from entry: NutritionEntry) -> Double {
            switch self {
            case .calories: entry.calories
            case .protein: entry.protein
            case .carbs: entry.carbs
            case .fat: entry.fat
            }
        }
    }

    var name: String {
        switch self {
        case .micro(let n): n.name
        case .macro(let m): m.rawValue
        }
    }

    var unit: String {
        switch self {
        case .micro(let n): n.unit
        case .macro(let m): m.unit
        }
    }

    var dailyValue: Double {
        switch self {
        case .micro(let n): n.dailyValue
        case .macro: 0 // handled via UserGoals
        }
    }
}

struct NutrientBreakdownView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    let kind: NutrientKind
    let period: NutritionStore.TimePeriod

    @State private var contributions: [FoodContribution] = []  // Full list (no zeros)
    @State private var chartSlices: [FoodContribution] = []    // Top N + "Other" for donut
    @State private var total: Double = 0

    /// Convenience init for micronutrients (used from NutrientProgressRow)
    init(nutrient: KnownMicronutrient, period: NutritionStore.TimePeriod) {
        self.kind = .micro(nutrient)
        self.period = period
    }

    /// Convenience init for macronutrients (used from macro cards)
    init(macro: NutrientKind.MacroType, period: NutritionStore.TimePeriod) {
        self.kind = .macro(macro)
        self.period = period
    }

    /// The daily value target, using UserGoals for macros
    private var effectiveDailyValue: Double {
        switch kind {
        case .micro(let n): n.dailyValue
        case .macro(let m):
            switch m {
            case .calories: goals.dailyCalories
            case .protein: goals.dailyProtein
            case .carbs: goals.dailyCarbs
            case .fat: goals.dailyFat
            }
        }
    }

    var body: some View {
        List {
            if !contributions.isEmpty {
                // Donut chart + totals
                Section {
                    VStack(spacing: 12) {
                        donutChart
                            .frame(height: 220)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatValue(total) + " " + kind.unit)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text("consumed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if effectiveDailyValue > 0 {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(Int((total / effectiveDailyValue) * 100))%")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundStyle(fractionColor(total / effectiveDailyValue))
                                    Text("of daily value")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                // Per-food breakdown
                Section("By Food") {
                    ForEach(contributions) { item in
                        ContributionRow(
                            item: item,
                            total: total,
                            dailyValue: effectiveDailyValue,
                            unit: kind.unit
                        )
                    }
                }
            } else {
                Section {
                    Text("No \(kind.name.lowercased()) logged \(periodLabel).")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(kind.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadData() }
    }

    // MARK: - Donut Chart

    private var donutChart: some View {
        Chart(chartSlices) { item in
            SectorMark(
                angle: .value("Amount", item.value),
                innerRadius: .ratio(0.6),
                angularInset: 1.5
            )
            .foregroundStyle(item.color)
            .cornerRadius(4)
        }
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: 2) {
                Text("\(contributions.count)")
                    .font(.title)
                    .fontWeight(.bold)
                Text(contributions.count == 1 ? "food" : "foods")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Data

    private var periodLabel: String {
        switch period {
        case .daily: "today"
        case .weekly: "this week"
        case .monthly: "this month"
        }
    }

    private func loadData() {
        let entries = nutritionStore.entriesForPeriod(period)

        // Group by food name and sum the nutrient value
        var byFood: [String: Double] = [:]
        for entry in entries {
            let value: Double
            switch kind {
            case .micro(let nutrient):
                guard let micro = entry.micronutrients[nutrient.id] else { continue }
                value = micro.value
            case .macro(let macroType):
                value = macroType.value(from: entry)
            }
            byFood[entry.name, default: 0] += value
        }

        // Filter out zero-value foods and sort by contribution (largest first)
        let sorted = byFood.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red, .mint, .indigo]

        contributions = sorted.enumerated().map { index, pair in
            FoodContribution(
                id: pair.key,
                foodName: pair.key,
                value: pair.value,
                color: palette[index % palette.count]
            )
        }
        total = contributions.reduce(0) { $0 + $1.value }

        // Build chart slices: show top 8, group the rest as "Other"
        let maxSlices = 8
        if contributions.count <= maxSlices {
            chartSlices = contributions
        } else {
            let top = Array(contributions.prefix(maxSlices))
            let otherTotal = contributions.dropFirst(maxSlices).reduce(0) { $0 + $1.value }
            chartSlices = top + [FoodContribution(
                id: "_other",
                foodName: "Other",
                value: otherTotal,
                color: .gray
            )]
        }
    }

    private func fractionColor(_ fraction: Double) -> Color {
        if fraction > 1.0 { return .red }
        if fraction > 0.8 { return .orange }
        return .green
    }

    private func formatValue(_ value: Double) -> String {
        if value < 1 && value > 0 {
            return String(format: "%.1f", value)
        } else if value >= 1000 {
            return String(format: "%.0f", value)
        } else if value == floor(value) {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }
}

// MARK: - Food Contribution Model

struct FoodContribution: Identifiable {
    let id: String
    let foodName: String
    let value: Double
    let color: Color
}

// MARK: - Contribution Row

private struct ContributionRow: View {
    let item: FoodContribution
    let total: Double
    let dailyValue: Double
    let unit: String

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return item.value / total
    }

    private var dvFraction: Double {
        guard dailyValue > 0 else { return 0 }
        return item.value / dailyValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(item.color)
                    .frame(width: 10, height: 10)

                Text(item.foodName)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                Text(formatValue(item.value) + " " + unit)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Text("(\(Int(fraction * 100))%)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            // Progress bar showing contribution to daily value
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 6)

                    Capsule()
                        .fill(item.color)
                        .frame(
                            width: min(geometry.size.width, geometry.size.width * dvFraction),
                            height: 6
                        )
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
    }

    private func formatValue(_ value: Double) -> String {
        if value < 1 && value > 0 {
            return String(format: "%.1f", value)
        } else if value >= 1000 {
            return String(format: "%.0f", value)
        } else if value == floor(value) {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }
}
