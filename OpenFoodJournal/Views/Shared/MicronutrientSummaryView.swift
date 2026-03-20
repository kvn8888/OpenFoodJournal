// OpenFoodJournal — MicronutrientSummaryView
// A glanceable list of all micronutrients with progress bars showing
// consumed vs. FDA daily value. Supports daily, weekly, and monthly views.
//
// Design: Each nutrient row shows:
//   [Name] ───────[progress bar]─────── [consumed / daily value]
//
// Common nutrients (sodium, fiber, calcium, iron, etc.) are always visible.
// Uncommon nutrients are collapsed under a "Show More" toggle.
// Unknown nutrients from Gemini appear in a separate "Other" section.
// AGPL-3.0 License

import SwiftUI

struct MicronutrientSummaryView: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(NutritionStore.self) private var nutritionStore

    // ── State ─────────────────────────────────────────────────────
    @State private var selectedPeriod: NutritionStore.TimePeriod = .daily
    @State private var showUncommon = false     // Toggle for less-common nutrients
    @State private var aggregated: [String: MicronutrientValue] = [:]

    var body: some View {
        NavigationStack {
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

                // Subtitle explaining the view for weekly/monthly
                if selectedPeriod != .daily {
                    Section {
                        Text("Showing daily average over \(selectedPeriod == .weekly ? "7" : "30") days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }

                // Common nutrients — always visible
                commonNutrientsSections

                // Uncommon nutrients — expandable
                uncommonNutrientsSection

                // Unknown nutrients from Gemini not in our known list
                unknownNutrientsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Micronutrients")
            .onChange(of: selectedPeriod) { _, _ in
                refreshData()
            }
            .onAppear {
                refreshData()
            }
        }
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
                        NutrientProgressRow(
                            nutrient: nutrient,
                            consumed: aggregated[nutrient.id]
                        )
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
