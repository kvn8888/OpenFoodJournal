// OpenFoodJournal — EditFoodSheet
// Allows editing a SavedFood's identity, macros, and micronutrients.
// Presented from FoodBankView via swipe action or context menu.
// Changes are saved to SwiftData.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct EditFoodSheet: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(TursoMirrorService.self) private var tursoMirror

    // ── The food being edited (Bindable allows two-way binding to @Model properties)
    @Bindable var food: SavedFood

    // ── Local state for text fields (buffered until Save) ─────────
    @State private var name: String = ""
    @State private var brand: String = ""
    @State private var calories: String = ""
    @State private var protein: String = ""
    @State private var carbs: String = ""
    @State private var fat: String = ""
    @State private var servingSize: String = ""
    @State private var micronutrientValues: [String: String] = [:]
    @State private var micronutrientUnits: [String: String] = [:]
    @State private var isOnShelf = false
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                // Identity — name and brand
                Section("Identity") {
                    TextField("Food name", text: $name)
                    TextField("Brand (optional)", text: $brand)
                    Toggle(isOn: $isOnShelf) {
                        Label("On Shelf", systemImage: isOnShelf ? "cabinet.fill" : "cabinet")
                    }
                }

                // Core macros
                Section("Nutrition (per serving)") {
                    MacroField(label: "Calories", unit: "kcal", text: $calories)
                    MacroField(label: "Protein", unit: "g", text: $protein)
                    MacroField(label: "Carbs", unit: "g", text: $carbs)
                    MacroField(label: "Fat", unit: "g", text: $fat)
                }

                Section("Micronutrients (per serving)") {
                    ForEach(sortedMicronutrientKeys, id: \.self) { key in
                        MicronutrientEditRow(
                            label: KnownMicronutrients.nutrient(forID: key)?.name ?? key,
                            value: Binding(
                                get: { micronutrientValues[key] ?? "" },
                                set: { micronutrientValues[key] = $0 }
                            ),
                            unit: Binding(
                                get: { micronutrientUnits[key] ?? "" },
                                set: { micronutrientUnits[key] = $0 }
                            ),
                            onDelete: {
                                micronutrientValues.removeValue(forKey: key)
                                micronutrientUnits.removeValue(forKey: key)
                            }
                        )
                    }

                    Menu {
                        ForEach(availableMicronutrients) { nutrient in
                            Button(nutrient.name) {
                                micronutrientValues[nutrient.id] = "0"
                                micronutrientUnits[nutrient.id] = nutrient.unit
                            }
                        }
                    } label: {
                        Label("Add Micronutrient", systemImage: "plus.circle")
                    }
                    .disabled(availableMicronutrients.isEmpty)
                }

                // Serving info
                Section("Serving") {
                    TextField("Serving size (e.g. 1 cup, 170g)", text: $servingSize)
                }

                // Danger zone — delete is intentionally buried here, not on the swipe action
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete from Food Bank", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .confirmationDialog(
                "Delete \(food.name)?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let foodId = food.id
                    modelContext.delete(food)
                    try? modelContext.save()
                    tursoMirror.scheduleMirror(reason: "saved_food_deleted")
                    dismiss()
                }
            } message: {
                Text("This food will be removed from your Food Bank. Journal entries that used it won't be affected.")
            }
            .navigationTitle("Edit Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
            .onAppear {
                // Populate fields from the food model
                name = food.name
                brand = food.brand ?? ""
                calories = String(format: "%.0f", food.calories)
                protein = String(format: "%.1f", food.protein)
                carbs = String(format: "%.1f", food.carbs)
                fat = String(format: "%.1f", food.fat)
                servingSize = food.servingSize ?? ""
                micronutrientValues = food.micronutrients.mapValues {
                    $0.value.formatted(.number.precision(.fractionLength(0...3)))
                }
                micronutrientUnits = food.micronutrients.mapValues(\.unit)
                isOnShelf = food.isOnShelf
            }
        }
    }

    // MARK: - Save Changes

    private var sortedMicronutrientKeys: [String] {
        micronutrientValues.keys.sorted {
            let first = KnownMicronutrients.nutrient(forID: $0)?.name ?? $0
            let second = KnownMicronutrients.nutrient(forID: $1)?.name ?? $1
            return first.localizedCaseInsensitiveCompare(second) == .orderedAscending
        }
    }

    private var availableMicronutrients: [KnownMicronutrient] {
        KnownMicronutrients.all.filter { micronutrientValues[$0.id] == nil }
    }

    /// Apply buffered text field values back to the SwiftData model and sync
    private func saveChanges() {
        food.name = name.trimmingCharacters(in: .whitespaces)
        food.brand = brand.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : brand.trimmingCharacters(in: .whitespaces)
        food.calories = Double(calories) ?? food.calories
        food.protein = Double(protein) ?? food.protein
        food.carbs = Double(carbs) ?? food.carbs
        food.fat = Double(fat) ?? food.fat
        food.micronutrients = Dictionary(uniqueKeysWithValues:
            sortedMicronutrientKeys.compactMap { key in
                guard let value = Double(micronutrientValues[key] ?? ""),
                      value.isFinite,
                      value >= 0
                else { return nil }
                let unit = micronutrientUnits[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let unit, !unit.isEmpty else { return nil }
                return (key, MicronutrientValue(value: value, unit: unit))
            }
        )
        food.servingSize = servingSize.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : servingSize.trimmingCharacters(in: .whitespaces)
        food.isOnShelf = isOnShelf

        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "saved_food_updated")
    }
}

private struct MicronutrientEditRow: View {
    let label: String
    @Binding var value: String
    @Binding var unit: String
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: $value)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
                .accessibilityLabel("\(label) amount")
            TextField("unit", text: $unit)
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.leading)
                .frame(width: 48)
                .accessibilityLabel("\(label) unit")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle")
                    .accessibilityLabel("Remove \(label)")
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Macro Field

/// Reusable row for editing a numeric macro value.
private struct MacroField: View {
    let label: String
    let unit: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }
}
