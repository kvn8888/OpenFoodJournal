// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

/// Edit a logged entry — adjust serving quantity, unit, and meal type.
/// Core macros are read-only here; edit the food itself in Food Bank.
/// Macros scale proportionally when the user changes quantity or unit.
struct EditEntryView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(HealthKitService.self) private var healthKit
    @Environment(\.dismiss) private var dismiss

    @Bindable var entry: NutritionEntry

    @State private var showDeleteConfirm = false

    // Editable serving quantity — initialized from the entry's current value
    @State private var quantity: Double

    // Text backing for the quantity field (avoids cursor-jump issues with Double binding)
    @State private var quantityText: String

    // Editable unit — picker populated from the entry's serving mappings
    @State private var selectedUnit: String

    // Snapshot of the entry's macros/quantity/unit at the time the view opens.
    // These never change during editing — they're the baseline for scaling.
    private let baseCalories: Double
    private let baseProtein: Double
    private let baseCarbs: Double
    private let baseFat: Double
    private let baseQuantity: Double
    private let baseUnit: String

    init(entry: NutritionEntry) {
        self.entry = entry
        let qty = entry.servingQuantity ?? 1.0
        let unit = entry.servingUnit ?? "serving"
        _quantity = State(initialValue: qty)
        _quantityText = State(initialValue: qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", qty) : String(format: "%.2f", qty))
        _selectedUnit = State(initialValue: unit)
        self.baseCalories = entry.calories
        self.baseProtein = entry.protein
        self.baseCarbs = entry.carbs
        self.baseFat = entry.fat
        self.baseQuantity = max(qty, 0.01) // avoid division by zero
        self.baseUnit = unit
    }

    // MARK: - Computed helpers

    /// All unique units the user can pick from (current unit + all mapping endpoints)
    private var availableUnits: [String] {
        var units = Set<String>()
        units.insert(baseUnit) // always include the original unit
        for mapping in entry.servingMappings {
            units.insert(mapping.from.unit)
            units.insert(mapping.to.unit)
        }
        return units.sorted()
    }

    /// Conversion factor: how many selectedUnit equal 1 baseUnit.
    /// e.g. if baseUnit is "cup" and selectedUnit is "g", and mapping says 1 cup = 244 g,
    /// then unitFactor = 244.0. Falls back to 1.0 if no mapping exists.
    private var unitFactor: Double {
        if selectedUnit == baseUnit { return 1.0 }
        return conversionFactor(from: baseUnit, to: selectedUnit) ?? 1.0
    }

    /// Macros per 1 base-unit (e.g. calories per 1 cup)
    private var calPerBaseUnit: Double { baseCalories / baseQuantity }
    private var proPerBaseUnit: Double { baseProtein / baseQuantity }
    private var carbPerBaseUnit: Double { baseCarbs / baseQuantity }
    private var fatPerBaseUnit: Double { baseFat / baseQuantity }

    /// Scaled macros for the current quantity and unit selection.
    /// Formula: (macros per base-unit) / unitFactor * quantity
    /// This correctly handles both quantity changes and unit conversions.
    private var displayCalories: Double { calPerBaseUnit / unitFactor * quantity }
    private var displayProtein: Double { proPerBaseUnit / unitFactor * quantity }
    private var displayCarbs: Double { carbPerBaseUnit / unitFactor * quantity }
    private var displayFat: Double { fatPerBaseUnit / unitFactor * quantity }

    var body: some View {
        NavigationStack {
            Form {
                foodInfoSection
                mealSection
                servingSection
                nutritionSection
                deleteSection
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                // Done button above the keyboard to dismiss it
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Write the scaled macros back to the entry
                        entry.calories = displayCalories
                        entry.protein = displayProtein
                        entry.carbs = displayCarbs
                        entry.fat = displayFat
                        entry.servingQuantity = quantity
                        entry.servingUnit = selectedUnit

                        nutritionStore.saveAndSyncEntry(entry)
                        Task { await healthKit.write(entry) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Delete this entry?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    nutritionStore.delete(entry)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            // When the user picks a different unit, auto-convert the quantity
            // so the total food amount stays the same (e.g. 2 cups → 488 g)
            .onChange(of: selectedUnit) { oldUnit, newUnit in
                if let factor = conversionFactor(from: oldUnit, to: newUnit) {
                    quantity *= factor
                }
            }
        }
    }

    // MARK: - Form sections (extracted to help the Swift type checker)

    /// Food name, brand, and scan confidence — all read-only
    private var foodInfoSection: some View {
        Section {
            if let brand = entry.brand, !brand.isEmpty {
                Text(brand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.name)
                .font(.headline)

            if let pct = entry.confidencePercent {
                HStack {
                    Label(
                        entry.scanMode == .label ? "Scanned from label" : "Estimated from photo",
                        systemImage: entry.scanMode == .label ? "barcode.viewfinder" : "camera.viewfinder"
                    )
                    Spacer()
                    Text("\(pct)%")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(entry.scanMode == .label ? .teal : .orange)
            }
        }
    }

    /// Meal type picker
    private var mealSection: some View {
        Section {
            Picker("Meal", selection: $entry.mealType) {
                ForEach(MealType.allCases) { type in
                    Label(type.rawValue, systemImage: type.systemImage)
                        .tag(type)
                }
            }
        }
    }

    /// Quantity text field and unit picker
    private var servingSection: some View {
        Section("Serving") {
            HStack {
                Text("Quantity")
                Spacer()
                TextField("1", text: $quantityText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: quantityText) { _, newVal in
                        if let val = Double(newVal), val > 0 {
                            quantity = val
                        }
                    }
            }

            if availableUnits.count > 1 {
                Picker("Unit", selection: $selectedUnit) {
                    ForEach(availableUnits, id: \.self) { unit in
                        Text(unit).tag(unit)
                    }
                }
            } else {
                HStack {
                    Text("Unit")
                    Spacer()
                    Text(selectedUnit)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Read-only macros scaled by the current serving selection
    private var nutritionSection: some View {
        Section("Nutrition") {
            MacroDisplayRow(label: "Calories", value: displayCalories, unit: "kcal")
            MacroDisplayRow(label: "Protein", value: displayProtein, unit: "g")
            MacroDisplayRow(label: "Carbs", value: displayCarbs, unit: "g")
            MacroDisplayRow(label: "Fat", value: displayFat, unit: "g")
        }
    }

    /// Delete entry button
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete Entry", systemImage: "trash")
            }
        }
    }

    // MARK: - Unit conversion

    /// Returns how many `toUnit` equal 1 `fromUnit` using the entry's serving mappings.
    /// e.g. if mapping says 1 cup = 244 g, then conversionFactor(from: "cup", to: "g") = 244.
    /// Checks both directions (from→to and to→from) of each mapping.
    private func conversionFactor(from fromUnit: String, to toUnit: String) -> Double? {
        if fromUnit == toUnit { return 1.0 }
        for mapping in entry.servingMappings {
            // Direct match: mapping.from → mapping.to
            if mapping.from.unit == fromUnit && mapping.to.unit == toUnit {
                return mapping.to.value / mapping.from.value
            }
            // Reverse match: mapping.to → mapping.from
            if mapping.to.unit == fromUnit && mapping.from.unit == toUnit {
                return mapping.from.value / mapping.to.value
            }
        }
        return nil
    }
}

// MARK: - MacroDisplayRow

/// A read-only row showing a macro label, numeric value, and unit.
/// Used in EditEntryView where macros are display-only (scaled by serving).
private struct MacroDisplayRow: View {
    let label: String
    let value: Double
    let unit: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%.1f", value))
                .foregroundStyle(.secondary)
            Text(unit)
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
        }
    }
}

#Preview {
    EditEntryView(entry: NutritionEntry.preview)
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(HealthKitService())
}
