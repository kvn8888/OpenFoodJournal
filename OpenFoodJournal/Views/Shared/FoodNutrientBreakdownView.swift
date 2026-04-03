// OpenFoodJournal — FoodNutrientBreakdownView
// Shows all nutrients (macros + micros) for a specific food across the selected period.
// This is the inverse of NutrientBreakdownView: food → all nutrients (vs nutrient → all foods).
//
// Accessed by tapping a food row in NutrientBreakdownView's "By Food" section.
//
// Layout:
//   [Header: food name + total servings consumed in period]
//   [Macro rings: Cal / Protein / Carbs / Fat — circular progress vs goals]
//   [Micronutrient rows: each known micronutrient found in this food, with DV% bars]
//
// AGPL-3.0 License

import SwiftUI

struct FoodNutrientBreakdownView: View {
    // ── Environment ─────────────────────────────────────────────
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    // ── Inputs ──────────────────────────────────────────────────
    /// The food name to filter entries by (matches NutritionEntry.name)
    let foodName: String
    /// Which time period to aggregate over (daily/weekly/monthly)
    let period: NutritionStore.TimePeriod

    // ── Computed Data ───────────────────────────────────────────
    @State private var entries: [NutritionEntry] = []
    @State private var macros: (cal: Double, protein: Double, carbs: Double, fat: Double) = (0, 0, 0, 0)
    @State private var micronutrients: [MicroRow] = []

    var body: some View {
        List {
            // Header: how many servings of this food were logged
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(entries.count) \(entries.count == 1 ? "serving" : "servings") logged")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(periodLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .listRowBackground(Color.clear)
            }

            // Macro summary as circular rings (matching NutritionDetailView)
            Section("Macros") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    macroRing("Calories", value: macros.cal, goal: Double(goals.dailyCalories), unit: "kcal", color: .orange)
                    macroRing("Protein", value: macros.protein, goal: Double(goals.dailyProtein), unit: "g", color: .blue)
                    macroRing("Carbs", value: macros.carbs, goal: Double(goals.dailyCarbs), unit: "g", color: .green)
                    macroRing("Fat", value: macros.fat, goal: Double(goals.dailyFat), unit: "g", color: .yellow)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            // Micronutrient rows grouped by category
            if !micronutrients.isEmpty {
                ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                    let rows = micronutrients.filter { $0.category == category }
                    if !rows.isEmpty {
                        Section(category.rawValue) {
                            ForEach(rows) { row in
                                micronutrientRow(row)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(foodName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadData() }
    }

    // MARK: - Macro Ring

    /// A single circular progress ring for one macro, matching the style in NutritionDetailView
    private func macroRing(_ name: String, value: Double, goal: Double, unit: String, color: Color) -> some View {
        let fraction = goal > 0 ? min(value / goal, 1.5) : 0
        let displayFraction = min(fraction, 1.0)

        return VStack(spacing: 4) {
            ZStack {
                // Background track
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 6)
                // Filled arc
                Circle()
                    .trim(from: 0, to: displayFraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // Value inside the ring
                VStack(spacing: 0) {
                    Text("\(Int(value))")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(color)
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)

            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)

            if goal > 0 {
                Text("\(Int(fraction * 100))%")
                    .font(.caption2)
                    .foregroundStyle(fraction >= 1.0 ? color : .secondary)
            }
        }
    }

    // MARK: - Micronutrient Row

    /// Shows a single micronutrient with its value, daily value percentage, and progress bar
    private func micronutrientRow(_ row: MicroRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.name)
                    .font(.subheadline)
                Spacer()
                Text(row.valueText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // Progress bar vs daily value
            if row.dailyValue > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 6)
                        Capsule()
                            .fill(row.progressColor)
                            .frame(
                                width: min(geometry.size.width, geometry.size.width * min(row.fraction, 1.0)),
                                height: 6
                            )
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data Loading

    /// Collects all entries matching this food name in the period, then aggregates nutrients
    private func loadData() {
        // Get all entries for the period, filter to this food
        let allEntries = nutritionStore.entriesForPeriod(period)
        entries = allEntries.filter { $0.name == foodName }

        // Sum macros across all matching entries
        macros = entries.reduce(into: (cal: 0.0, protein: 0.0, carbs: 0.0, fat: 0.0)) { result, entry in
            result.cal += entry.calories
            result.protein += entry.protein
            result.carbs += entry.carbs
            result.fat += entry.fat
        }

        // Aggregate micronutrients: sum each nutrient across all entries
        var microTotals: [String: Double] = [:]
        var microUnits: [String: String] = [:]

        for entry in entries {
            for (key, value) in entry.micronutrients {
                microTotals[key, default: 0] += value.value
                microUnits[key] = value.unit
            }
        }

        // Map to MicroRow using known nutrients for daily value / category info
        var rows: [MicroRow] = []
        for (key, total) in microTotals {
            let known = KnownMicronutrients.all.first { $0.id == key }
            rows.append(MicroRow(
                id: key,
                name: known?.name ?? key.replacingOccurrences(of: "_", with: " ").capitalized,
                value: total,
                unit: microUnits[key] ?? known?.unit ?? "",
                dailyValue: known?.dailyValue ?? 0,
                category: known?.category ?? .other
            ))
        }

        // Sort: by category, then by name within category
        micronutrients = rows.sorted { a, b in
            if a.category != b.category {
                return a.category.sortOrder < b.category.sortOrder
            }
            return a.name < b.name
        }
    }

    private var periodLabel: String {
        switch period {
        case .daily: "Today"
        case .weekly: "This week"
        case .monthly: "This month"
        }
    }
}

// MARK: - MicroRow Model

/// Lightweight struct holding aggregated micronutrient data for display
private struct MicroRow: Identifiable {
    let id: String
    let name: String
    let value: Double
    let unit: String
    let dailyValue: Double
    let category: KnownMicronutrient.Category

    /// Fraction of daily value consumed (0 to ∞)
    var fraction: Double {
        guard dailyValue > 0 else { return 0 }
        return value / dailyValue
    }

    /// Color based on how close to daily value
    var progressColor: Color {
        if fraction > 1.0 { return .red }
        if fraction > 0.8 { return .orange }
        return .green
    }

    /// Formatted text like "45 / 2300 mg (85%)"
    var valueText: String {
        let dvText = dailyValue == 0 ? "—" : formatValue(dailyValue)
        let pctText = dailyValue > 0 ? String(format: " (%.0f%%)", fraction * 100) : ""
        return "\(formatValue(value)) / \(dvText) \(unit)\(pctText)"
    }

    private func formatValue(_ v: Double) -> String {
        if v < 1 && v > 0 { return String(format: "%.1f", v) }
        if v >= 1000 { return String(format: "%.0f", v) }
        if v == floor(v) { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }
}

// MARK: - Category Sort Order

private extension KnownMicronutrient.Category {
    /// Consistent ordering: Vitamins first, then Minerals, then Other
    var sortOrder: Int {
        switch self {
        case .vitamin: 0
        case .mineral: 1
        case .other: 2
        }
    }
}
