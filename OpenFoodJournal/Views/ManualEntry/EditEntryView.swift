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
    @Environment(SyncService.self) private var syncService
    @Environment(\.dismiss) private var dismiss

    @Bindable var entry: NutritionEntry

    @State private var showDeleteConfirm = false
    // Controls the AddServingMappingSheet for adding custom unit conversions
    @State private var showAddMapping = false

    // Editable serving quantity — initialized from the entry's current value
    @State private var quantity: Double

    // Text backing for the quantity field (avoids cursor-jump issues with Double binding)
    @State private var quantityText: String

    // Editable unit — picker populated from the entry's serving mappings
    @State private var selectedUnit: String

    // Centralised unit conversion + macro scaling logic (shared with LogFoodSheet)
    private let converter: ServingConverter

    // Keep baseUnit accessible for onChange unit-switch logic
    private let baseUnit: String

    init(entry: NutritionEntry) {
        self.entry = entry
        let qty = entry.servingQuantity ?? 1.0
        let unit = entry.servingUnit ?? "serving"
        _quantity = State(initialValue: qty)
        _quantityText = State(initialValue: qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", qty) : String(format: "%.2f", qty))
        _selectedUnit = State(initialValue: unit)
        self.baseUnit = unit
        self.converter = ServingConverter(
            calories: entry.calories,
            protein: entry.protein,
            carbs: entry.carbs,
            fat: entry.fat,
            quantity: qty,
            unit: unit,
            serving: entry.serving,
            mappings: entry.servingMappings
        )
    }

    // MARK: - Computed helpers (delegated to ServingConverter)

    private var availableUnits: [String] { converter.availableUnits }
    private var unitFactor: Double { converter.factorFor(selectedUnit) }
    private var displayCalories: Double { converter.scaledCalories(quantity: quantity, unit: selectedUnit) }
    private var displayProtein: Double { converter.scaledProtein(quantity: quantity, unit: selectedUnit) }
    private var displayCarbs: Double { converter.scaledCarbs(quantity: quantity, unit: selectedUnit) }
    private var displayFat: Double { converter.scaledFat(quantity: quantity, unit: selectedUnit) }

    var body: some View {
        NavigationStack {
            Form {
                foodInfoSection
                mealSection
                servingSection
                servingMappingsSection
                nutritionSection
                deleteSection
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showAddMapping) {
                // Reuses the same AddServingMappingSheet from LogFoodSheet.swift.
                // The onAdd callback mutates entry.servingMappings and saves to
                // SwiftData, making the new unit appear in the unit picker above.
                AddServingMappingSheet { mapping in
                    addMapping(mapping)
                }
            }
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
                let oldFactor = converter.factorFor(oldUnit)
                let newFactor = converter.factorFor(newUnit)
                guard oldFactor > 0, newFactor > 0 else { return }
                let converted = quantity * newFactor / oldFactor
                quantity = converted
                quantityText = converted.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", converted)
                    : String(format: "%.2f", converted)
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

    // MARK: - Serving Mappings

    /// Shows existing unit mappings (e.g. "1 cup → 244 g") and an Add button.
    /// Adding a mapping to an entry lets the user switch between units — especially
    /// useful for volume-only foods where a custom weight mapping isn't in the
    /// standard table (e.g. a thick smoothie has different density than water).
    private var servingMappingsSection: some View {
        Section {
            if entry.servingMappings.isEmpty {
                // Hint text — explains what mappings do and when they're useful
                Text("Add custom unit conversions (e.g. 1 cup = 250 g) to switch between measurement dimensions in the unit picker above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.servingMappings, id: \.self) { mapping in
                    HStack(spacing: 6) {
                        Text(mapping.from.displayString)
                            .fontWeight(.medium)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(mapping.to.displayString)
                        Spacer()
                    }
                    .font(.subheadline)
                }
            }

            Button {
                showAddMapping = true
            } label: {
                Label("Add Unit Mapping", systemImage: "plus")
            }
        } header: {
            Text("Unit Mappings")
        }
    }

    /// Appends a new mapping to the entry, saves to SwiftData, and syncs.
    private func addMapping(_ mapping: ServingMapping) {
        entry.servingMappings.append(mapping)
        nutritionStore.saveAndSyncEntry(entry)
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
