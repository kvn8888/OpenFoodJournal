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
    @State private var selectedDate: Date = .now
    @State private var showUncommon = false     // Toggle for less-common nutrients
    @State private var aggregated: [String: MicronutrientValue] = [:]
    @State private var macroTotals: (cal: Double, protein: Double, carbs: Double, fat: Double) = (0, 0, 0, 0)
    @State private var selectedMacro: NutrientKind.MacroType?

    private let calendar = Calendar.current

    /// Whether the user can navigate forward (can't go past today/current period)
    private var canGoForward: Bool {
        let today = calendar.startOfDay(for: .now)
        let current = calendar.startOfDay(for: selectedDate)
        return current < today
    }

    /// Formatted date label based on the selected period.
    /// Weekly/monthly show a trailing window ending on selectedDate.
    private var dateLabel: String {
        switch selectedPeriod {
        case .daily:
            if calendar.isDateInToday(selectedDate) {
                return "Today"
            } else if calendar.isDateInYesterday(selectedDate) {
                return "Yesterday"
            }
            return selectedDate.formatted(.dateTime.month(.abbreviated).day())
        case .weekly:
            let start = calendar.date(byAdding: .day, value: -6, to: selectedDate)!
            let startStr = start.formatted(.dateTime.month(.abbreviated).day())
            let endStr = selectedDate.formatted(.dateTime.month(.abbreviated).day())
            return "\(startStr) – \(endStr)"
        case .monthly:
            let start = calendar.date(byAdding: .day, value: -29, to: selectedDate)!
            let startStr = start.formatted(.dateTime.month(.abbreviated).day())
            let endStr = selectedDate.formatted(.dateTime.month(.abbreviated).day())
            return "\(startStr) – \(endStr)"
        }
    }

    var body: some View {
        List {
            // Period picker + date navigation
            Section {
                Picker("Period", selection: $selectedPeriod) {
                    ForEach(NutritionStore.TimePeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                // Daily average hint for week/month
                if selectedPeriod != .daily {
                    Text("Showing daily averages")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                // Date nav: ◀ Date Label ▶
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            navigate(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.glass)

                        Text(dateLabel)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .glassEffect(in: .capsule)
                            .contentTransition(.numericText())

                        Button {
                            navigate(by: 1)
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
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Daily values based on a 2,000-calorie diet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Link("FDA Daily Value Guidelines", destination: URL(string: "https://www.fda.gov/food/nutrition-facts-label/daily-value-nutrition-and-supplement-facts-labels")!)
                        .font(.caption2)
                    Text("AI-estimated values are approximations.")
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
        .onChange(of: selectedDate) { _, _ in
            refreshData()
        }
        .onAppear {
            refreshData()
        }
        .animation(.easeInOut(duration: 0.2), value: selectedDate)
        .animation(.easeInOut(duration: 0.2), value: selectedPeriod)
    }

    // MARK: - Navigation

    /// Moves the selected date forward or backward by one period unit.
    /// Weekly/monthly step by 7/30 days to match the trailing-window aggregation.
    private func navigate(by direction: Int) {
        let dayStep: Int
        switch selectedPeriod {
        case .daily:   dayStep = 1
        case .weekly:  dayStep = 7
        case .monthly: dayStep = 30
        }
        guard let newDate = calendar.date(byAdding: .day, value: dayStep * direction, to: selectedDate) else { return }

        // Don't navigate past today
        let today = calendar.startOfDay(for: .now)
        if direction > 0 && calendar.startOfDay(for: newDate) > today {
            // Snap to today instead of overshooting
            if calendar.startOfDay(for: selectedDate) < today {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedDate = .now
                }
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = newDate
        }
    }

    // MARK: - Macro Summary

    private var macroSummarySection: some View {
        Section("Macros") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                macroCard(.calories, value: macroTotals.cal, goal: Double(goals.dailyCalories), color: .orange)
                macroCard(.protein, value: macroTotals.protein, goal: Double(goals.dailyProtein), color: .blue)
                macroCard(.carbs, value: macroTotals.carbs, goal: Double(goals.dailyCarbs), color: .green)
                macroCard(.fat, value: macroTotals.fat, goal: Double(goals.dailyFat), color: Color(red: 0.9, green: 0.75, blue: 0.0))
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private func macroCard(_ macro: NutrientKind.MacroType, value: Double, goal: Double, color: Color) -> some View {
        let fraction = goal > 0 ? min(value / goal, 1.5) : 0
        let displayFraction = min(fraction, 1.0) // Cap ring fill at 100%

        return Button {
            selectedMacro = macro
        } label: {
            VStack(spacing: 4) {
                // Circular progress ring replaces the linear ProgressView
                ZStack {
                    // Background track
                    Circle()
                        .stroke(color.opacity(0.15), lineWidth: 5)
                    // Filled arc — trims from 0 to fraction of circumference
                    Circle()
                        .trim(from: 0, to: displayFraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90)) // Start from 12 o'clock
                    // Value label inside the ring
                    VStack(spacing: 0) {
                        Text("\(Int(value))")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(color)
                        Text(macro.unit)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 100, height: 100)

                Text(macro.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Percentage label below the name (e.g. "85%")
                if goal > 0 {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption2)
                        .foregroundStyle(fraction >= 1.0 ? color : .secondary)
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
        aggregated = nutritionStore.aggregateMicronutrients(period: selectedPeriod, referenceDate: selectedDate)
        macroTotals = nutritionStore.aggregateMacros(period: selectedPeriod, referenceDate: selectedDate)
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
