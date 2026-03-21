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
    // Quantity of this food the user wants to log (in the selected unit)
    @State private var quantity: Double
    // Text backing for the quantity field — avoids cursor-jump with direct Double binding
    @State private var quantityText: String
    // The unit the user has selected for this log (may differ from the food's stored unit)
    @State private var selectedUnit: String

    // Snapshot of the food's baseline values at the time the sheet opens.
    // These never change; all display math is relative to these.
    private let baseCalories: Double
    private let baseProtein: Double
    private let baseCarbs: Double
    private let baseFat: Double
    private let baseQuantity: Double  // the food's stored serving quantity
    private let baseUnit: String      // the food's stored serving unit

    init(food: SavedFood) {
        self.food = food
        // Use the food's own serving quantity and unit as the starting point.
        // If not set, default to "1 serving" which maps to a 1x multiplier.
        let qty = food.servingQuantity ?? 1.0
        let unit = food.servingUnit ?? "serving"
        _quantity = State(initialValue: qty)
        // Show whole numbers without ".0", decimals up to 2 places
        _quantityText = State(initialValue: qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", qty) : String(format: "%.2f", qty))
        _selectedUnit = State(initialValue: unit)
        self.baseCalories = food.calories
        self.baseProtein = food.protein
        self.baseCarbs = food.carbs
        self.baseFat = food.fat
        self.baseQuantity = max(qty, 0.01)  // avoid division by zero
        self.baseUnit = unit
    }

    // MARK: - Serving computed helpers

    /// Units the user can switch between in the picker.
    /// Prefers the structured ServingSize enum when available, then supplements
    /// with any custom units from legacy servingMappings.
    private var availableUnits: [String] {
        if let serving = food.serving {
            var units = Set(serving.availableUnits)
            units.insert(baseUnit)
            for mapping in food.servingMappings {
                units.insert(mapping.from.unit)
                units.insert(mapping.to.unit)
            }
            return units.sorted()
        }
        // Legacy path — only the units explicitly covered by mappings
        var units = Set<String>()
        units.insert(baseUnit)
        for mapping in food.servingMappings {
            units.insert(mapping.from.unit)
            units.insert(mapping.to.unit)
        }
        return units.sorted()
    }

    /// How many selectedUnit equal 1 baseUnit.
    /// e.g. if baseUnit is "cup" and selectedUnit is "g", factor = 240 (1 cup = 240g).
    private var unitFactor: Double {
        if selectedUnit == baseUnit { return 1.0 }
        // Try the structured enum first (standardised mass/volume tables)
        if let factor = food.serving?.convert(1.0, from: baseUnit, to: selectedUnit) {
            return factor
        }
        // Fall back to explicit servingMappings for custom units
        for mapping in food.servingMappings {
            if mapping.from.unit == baseUnit && mapping.to.unit == selectedUnit {
                return mapping.to.value / mapping.from.value
            }
            if mapping.to.unit == baseUnit && mapping.from.unit == selectedUnit {
                return mapping.from.value / mapping.to.value
            }
        }
        return 1.0
    }

    // Macros expressed per single base-unit (e.g. kcal per 1 cup)
    private var calPerBaseUnit: Double { baseCalories / baseQuantity }
    private var proPerBaseUnit: Double { baseProtein / baseQuantity }
    private var carbPerBaseUnit: Double { baseCarbs / baseQuantity }
    private var fatPerBaseUnit: Double { baseFat / baseQuantity }

    /// Scaling multiplier for the log button — how much to multiply food.calories etc.
    /// Formula: (quantity in selectedUnit) / unitFactor / baseQuantity,
    /// then multiply by baseQuantity to get back to a simple scale factor.
    private var scaleFactor: Double { quantity / unitFactor / baseQuantity }

    /// Scaled macros for the current quantity + unit combination
    private var scaledCalories: Double { calPerBaseUnit / unitFactor * quantity }
    private var scaledProtein: Double   { proPerBaseUnit / unitFactor * quantity }
    private var scaledCarbs: Double     { carbPerBaseUnit / unitFactor * quantity }
    private var scaledFat: Double       { fatPerBaseUnit / unitFactor * quantity }

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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Log Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // "Done" dismisses the decimal pad keyboard
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
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
    /// and adds it to today's log via NutritionStore.
    /// Macros are scaled proportionally by the quantity/unit the user selected.
    private var logButton: some View {
        Button {
            // Create the entry from the food template
            var entry = food.toNutritionEntry(mealType: selectedMealType)
            // Scale all macros by the ratio of (selected quantity / base serving size)
            // using the same formula as EditEntryView: divide by unitFactor then by baseQuantity
            let factor = quantity / unitFactor / baseQuantity
            entry.calories *= factor
            entry.protein *= factor
            entry.carbs *= factor
            entry.fat *= factor
            // Scale micronutrients by the same factor
            for (key, micro) in entry.micronutrients {
                entry.micronutrients[key] = MicronutrientValue(
                    value: micro.value * factor,
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

    // MARK: - Serving Section

    /// Lets the user type a quantity and select a unit.
    /// The macro grid above live-updates as quantity and unit change.
    /// Mirrors the serving editor in EditEntryView.
    private var servingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quantity")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                // Quantity input — decimal keyboard, live-updates macros
                TextField("Amount", text: $quantityText)
                    .keyboardType(.decimalPad)
                    .font(.title2.monospacedDigit())
                    .fontWeight(.bold)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                    .onChange(of: quantityText) { _, newValue in
                        // Accept only valid positive numbers; ignore empty or non-numeric input
                        if let v = Double(newValue), v > 0 {
                            quantity = v
                        }
                    }

                // Unit picker — options come from the ServingSize enum or legacy mappings
                if availableUnits.count > 1 {
                    Picker("Unit", selection: $selectedUnit) {
                        ForEach(availableUnits, id: \.self) { unit in
                            Text(unit).tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.title2)
                    .fontWeight(.semibold)
                } else {
                    // Only one unit available — show it as static text
                    Text(selectedUnit)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }

            // Helper caption: what the food's canonical serving is
            if let size = food.servingSize {
                Text("1 serving = \(size)")
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
