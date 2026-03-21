// OpenFoodJournal — LogFoodSheet
// Presented when the user taps a saved food in the Food Bank.
// Shows the food's nutrition details and lets the user pick a meal type,
// then logs it to today's journal with one tap.
// AGPL-3.0 License

import SwiftUI

struct LogFoodSheet: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(NutritionStore.self) private var nutritionStore

    // ── Input: the saved food to potentially log ──────────────────
    let food: SavedFood

    // ── Local State ───────────────────────────────────────────────
    // The meal type the user selects before logging (defaults to snack)
    @State private var selectedMealType: MealType = .snack
    // Target date — defaults to today, could be extended to pick a date
    @State private var logDate: Date = .now
    // Serving quantity multiplier — 1.0 = one serving, 2.0 = double, etc.
    @State private var servingCount: Double = 1.0

    /// Scaled calories based on serving count
    private var scaledCalories: Double { food.calories * servingCount }
    private var scaledProtein: Double { food.protein * servingCount }
    private var scaledCarbs: Double { food.carbs * servingCount }
    private var scaledFat: Double { food.fat * servingCount }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // ── Food identity section ─────────────────────────
                    headerSection

                    Divider()

                    // ── Core macros grid ──────────────────────────────
                    macroGrid

                    // ── Micronutrients (if any) ──────────────────────
                    if !food.micronutrients.isEmpty {
                        micronutrientSection
                    }

                    Divider()

                    // ── Serving quantity adjustment ────────────────────
                    servingSection

                    Divider()

                    // ── Meal type picker ──────────────────────────────
                    mealPicker

                    // ── Log button ────────────────────────────────────
                    logButton
                }
                .padding()
            }
            .navigationTitle("Log Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    /// Shows the food name, serving size, and how it was originally captured
    private var headerSection: some View {
        VStack(spacing: 8) {
            // Source badge (label scan, food photo, or manual)
            HStack {
                Image(systemName: sourceIcon)
                Text(sourceLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: .capsule)

            // Brand (if available)
            if let brand = food.brand, !brand.isEmpty {
                Text(brand)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Food name
            Text(food.name)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            // Serving size if available
            if let serving = food.servingSize {
                Text(serving)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Macro Grid

    /// 2x2 grid showing calories, protein, carbs, and fat
    private var macroGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MacroCell(label: "Calories", value: scaledCalories, unit: "kcal", color: .orange)
            MacroCell(label: "Protein", value: scaledProtein, unit: "g", color: .blue)
            MacroCell(label: "Carbs", value: scaledCarbs, unit: "g", color: .green)
            MacroCell(label: "Fat", value: scaledFat, unit: "g", color: .yellow)
        }
    }

    // MARK: - Micronutrients

    /// Expandable section showing all dynamic micronutrients
    private var micronutrientSection: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                // Sort micronutrient names alphabetically for consistent display
                let sorted = food.micronutrients.keys.sorted()
                ForEach(sorted, id: \.self) { name in
                    if let micro = food.micronutrients[name] {
                        HStack {
                            Text(name)
                                .font(.subheadline)
                            Spacer()
                            Text("\(micro.value, specifier: "%.1f") \(micro.unit)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Micronutrients (\(food.micronutrients.count))", systemImage: "list.bullet")
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }

    // MARK: - Meal Picker

    /// Segmented picker for choosing which meal to log the food under
    private var mealPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log as")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Picker("Meal Type", selection: $selectedMealType) {
                ForEach(MealType.allCases) { meal in
                    Text(meal.rawValue.capitalized).tag(meal)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Log Button

    /// The primary action button: creates a NutritionEntry from the saved food
    /// and adds it to today's log via NutritionStore
    private var logButton: some View {
        Button {
            // Convert SavedFood → NutritionEntry with the selected meal type,
            // scaled by the serving count
            var entry = food.toNutritionEntry(mealType: selectedMealType)
            entry.calories *= servingCount
            entry.protein *= servingCount
            entry.carbs *= servingCount
            entry.fat *= servingCount
            // Scale micronutrients too
            for (key, micro) in entry.micronutrients {
                entry.micronutrients[key] = MicronutrientValue(
                    value: micro.value * servingCount,
                    unit: micro.unit
                )
            }
            nutritionStore.log(entry, to: logDate)
            dismiss()
        } label: {
            Text("Add to Journal")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - Serving Quantity

    /// Lets the user adjust how many servings they're logging.
    /// Shows +/- buttons and a text field for direct entry.
    private var servingSection: some View {
        VStack(spacing: 8) {
            Text("Servings")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                // Decrease button
                Button {
                    if servingCount > 0.25 {
                        servingCount -= 0.25
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .disabled(servingCount <= 0.25)

                // Serving count display
                Text(servingCount.truncatingRemainder(dividingBy: 1) == 0
                     ? String(format: "%.0f", servingCount)
                     : String(format: "%.2g", servingCount))
                    .font(.title)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .frame(minWidth: 60)

                // Increase button
                Button {
                    servingCount += 0.25
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
            }

            // Show what one serving is
            if let serving = food.servingSize {
                Text("1 serving = \(serving)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    /// SF Symbol for the food's original capture method
    private var sourceIcon: String {
        switch food.originalScanMode {
        case .label: "barcode.viewfinder"
        case .foodPhoto: "fork.knife"
        case .manual: "pencil.circle"
        }
    }

    /// Human-readable label for the food's origin
    private var sourceLabel: String {
        switch food.originalScanMode {
        case .label: "Label Scan"
        case .foodPhoto: "Food Photo"
        case .manual: "Manual Entry"
        }
    }
}

// MARK: - Macro Cell

/// A single macro display cell used in the 2x2 grid.
/// Shows a colored accent, the value, unit, and label.
private struct MacroCell: View {
    let label: String
    let value: Double
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(Int(value))")
                .font(.title2)
                .fontWeight(.bold)
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}
