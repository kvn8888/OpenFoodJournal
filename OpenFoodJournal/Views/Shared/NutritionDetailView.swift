// OpenFoodJournal — NutritionDetailView
// Unified nutrition view showing macros summary + micronutrient progress bars.
// Supports daily, weekly, and monthly averaging.
//
// Layout:
//   [Period picker: Daily | Weekly | Monthly]
//   [Macro summary cards: Cal / Protein / Carbs / Fat]
//   [Micronutrient sections with progress bars vs FDA daily value]
//
// AGPL-3.0 License

import SwiftUI

struct NutritionDetailView: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    // ── State ─────────────────────────────────────────────────────
    @State private var selectedPeriod: NutritionStore.TimePeriod = .daily
    @State private var showUncommon = false     // Toggle for less-common nutrients
    @State private var aggregated: [String: MicronutrientValue] = [:]
    @State private var macroTotals: (cal: Double, protein: Double, carbs: Double, fat: Double) = (0, 0, 0, 0)
    @State private var selectedMacro: NutrientKind.MacroType?

    var body: some View {
        List {
            // Time period picker at the top
            Section {
                Picker("Period", selection: $selectedPeriod) {
                    ForEach(NutritionStore.TimePeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            // Macro summary cards
            macroSummarySection

            // Common nutrients — always visible
            commonNutrientsSections

            // Uncommon nutrients — expandable
            uncommonNutrientsSection

            // Unknown nutrients from Gemini not in our known list
            unknownNutrientsSection

            // FDA citation footer — satisfies App Store Guideline 1.4.1
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Daily values based on a 2,000-calorie diet, per ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    + Text("[FDA guidelines](https://www.fda.gov/food/nutrition-facts-label/daily-value-nutrition-and-supplement-facts-labels)")
                        .font(.caption2)
                    + Text(". AI-estimated values are approximations.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Nutrition")
        .navigationDestination(item: $selectedMacro) { macro in
            NutrientBreakdownView(macro: macro, period: selectedPeriod)
        }
        .onChange(of: selectedPeriod) { _, _ in
            refreshData()
        }
        .onAppear {
            refreshData()
        }
    }

    // MARK: - Macro Summary

    private var macroSummarySection: some View {
        Section("Macros") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                macroCard(.calories, value: macroTotals.cal, goal: Double(goals.dailyCalories), color: .orange)
                macroCard(.protein, value: macroTotals.protein, goal: Double(goals.dailyProtein), color: .blue)
                macroCard(.carbs, value: macroTotals.carbs, goal: Double(goals.dailyCarbs), color: .green)
                macroCard(.fat, value: macroTotals.fat, goal: Double(goals.dailyFat), color: .yellow)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private func macroCard(_ macro: NutrientKind.MacroType, value: Double, goal: Double, color: Color) -> some View {
        Button {
            selectedMacro = macro
        } label: {
            VStack(spacing: 4) {
                Text("\(Int(value))")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(color)
                Text(macro.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(macro.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if goal > 0 {
                    ProgressView(value: min(value / goal, 1.0))
                        .tint(color)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Common Nutrients (grouped by category)

    /// Sections for common nutrients grouped by Vitamins / Minerals / Other
    @ViewBuilder
    private var commonNutrientsSections: some View {
        ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
            let nutrients = KnownMicronutrients.common.filter { $0.category == category }
            if !nutrients.isEmpty {
                Section(category.rawValue) {
                    ForEach(nutrients) { nutrient in
                        NavigationLink {
                            NutrientBreakdownView(nutrient: nutrient, period: selectedPeriod)
                        } label: {
                            NutrientProgressRow(
                                nutrient: nutrient,
                                consumed: aggregated[nutrient.id]
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Uncommon Nutrients (collapsible)

    /// Expandable section for less common nutrients (B vitamins, trace minerals, etc.)
    private var uncommonNutrientsSection: some View {
        Section {
            DisclosureGroup("More Nutrients", isExpanded: $showUncommon) {
                ForEach(KnownMicronutrient.Category.allCases, id: \.self) { category in
                    let nutrients = KnownMicronutrients.uncommon.filter { $0.category == category }
                    if !nutrients.isEmpty {
                        // Category header within the disclosure
                        Text(category.rawValue)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        ForEach(nutrients) { nutrient in
                            NavigationLink {
                                NutrientBreakdownView(nutrient: nutrient, period: selectedPeriod)
                            } label: {
                                NutrientProgressRow(
                                    nutrient: nutrient,
                                    consumed: aggregated[nutrient.id]
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Unknown Nutrients

    /// Any nutrients from Gemini that don't match our known list
    @ViewBuilder
    private var unknownNutrientsSection: some View {
        let knownIDs = Set(KnownMicronutrients.all.map(\.id))
        let unknownKeys = aggregated.keys.filter { !knownIDs.contains($0) }.sorted()

        if !unknownKeys.isEmpty {
            Section("Other (from scans)") {
                ForEach(unknownKeys, id: \.self) { key in
                    if let value = aggregated[key] {
                        HStack {
                            Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.subheadline)
                            Spacer()
                            Text("\(value.value, specifier: "%.1f") \(value.unit)")
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data Refresh

    private func refreshData() {
        aggregated = nutritionStore.aggregateMicronutrients(period: selectedPeriod)
        macroTotals = nutritionStore.aggregateMacros(period: selectedPeriod)
    }
}

// MARK: - Nutrient Progress Row

/// A single row showing nutrient name, progress bar, and consumed/daily value text.
/// The progress bar fills from left to right, colored by how close to the daily value:
/// - Green: 0–80% (on track)
/// - Orange: 80–100% (approaching target)
/// - Red: >100% (exceeded — for limit-type nutrients like sodium this is bad)
private struct NutrientProgressRow: View {
    let nutrient: KnownMicronutrient
    let consumed: MicronutrientValue?

    /// What fraction of the daily value has been consumed (0.0 to ∞)
    private var fraction: Double {
        guard let consumed, nutrient.dailyValue > 0 else { return 0 }
        return consumed.value / nutrient.dailyValue
    }

    /// Color of the progress bar based on fraction
    private var progressColor: Color {
        if fraction > 1.0 { return .red }
        if fraction > 0.8 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top: name and value text
            HStack {
                Text(nutrient.name)
                    .font(.subheadline)
                Spacer()
                Text(valueText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // Bottom: progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 6)

                    // Filled portion — capped at 100% visually
                    Capsule()
                        .fill(progressColor)
                        .frame(
                            width: min(geometry.size.width, geometry.size.width * fraction),
                            height: 6
                        )
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
    }

    /// Formatted text like "45 / 2300 mg" or "— / 2300 mg" if no data
    private var valueText: String {
        let dvText = nutrient.dailyValue == 0
            ? "—"
            : formatValue(nutrient.dailyValue)

        if let consumed {
            let pct = nutrient.dailyValue > 0
                ? String(format: " (%.0f%%)", fraction * 100)
                : ""
            return "\(formatValue(consumed.value)) / \(dvText) \(nutrient.unit)\(pct)"
        } else {
            return "— / \(dvText) \(nutrient.unit)"
        }
    }

    /// Formats a numeric value smartly: "0.9" for small, "45" for medium, "2300" for large
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
