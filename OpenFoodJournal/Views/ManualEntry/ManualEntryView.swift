// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

// Shared focus field enum — fileprivate so MacroInputRow can access it.
// Uses .micronutrient(String) to handle any dynamic nutrient name.
fileprivate enum ManualEntryField: Hashable {
    case name, brand, calories, protein, carbs, fat
    case micronutrient(String)  // dynamic: "Fiber", "Sugar", "Sodium", etc.
    case servingSize
}

struct ManualEntryView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let defaultDate: Date

    /// Optional OFF product to pre-fill the form with.
    /// When set, all fields are populated from the product's nutrition data
    /// and the user can review/edit before saving.
    let prefillProduct: OFFProduct?

    // Form state
    @State private var name = ""
    @State private var brand = ""
    @State private var mealType: MealType = .snack
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var showExtended = false

    // Dynamic micronutrient text fields — keyed by nutrient name.
    // Starts with common ones; user can add more.
    @State private var micronutrientTexts: [(name: String, unit: String, text: String)] = [
        ("Fiber", "g", ""),
        ("Sugar", "g", ""),
        ("Sodium", "mg", ""),
    ]

    @State private var servingSize = ""

    // State for adding a new micronutrient
    @State private var showAddMicro = false
    @State private var newMicroName = ""
    @State private var newMicroUnit = "g"

    @FocusState private var focusedField: ManualEntryField?

    /// Convenience initializer without pre-fill (backwards compatible)
    init(defaultDate: Date) {
        self.defaultDate = defaultDate
        self.prefillProduct = nil
    }

    /// Initializer with an OFF product to pre-fill the form
    init(defaultDate: Date, prefillProduct: OFFProduct) {
        self.defaultDate = defaultDate
        self.prefillProduct = prefillProduct
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && Double(calories) != nil
        && Double(protein) != nil
        && Double(carbs) != nil
        && Double(fat) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food Info") {
                    TextField("Food name", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .brand }

                    TextField("Brand (optional)", text: $brand)
                        .focused($focusedField, equals: .brand)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .calories }

                    Picker("Meal", selection: $mealType) {
                        ForEach(MealType.allCases) { type in
                            Label(type.rawValue, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }
                }

                Section("Core Macros") {
                    MacroInputRow(label: "Calories", unit: "kcal", text: $calories, field: .calories, focusedField: $focusedField, nextField: .protein)
                    MacroInputRow(label: "Protein", unit: "g", text: $protein, field: .protein, focusedField: $focusedField, nextField: .carbs)
                    MacroInputRow(label: "Carbs", unit: "g", text: $carbs, field: .carbs, focusedField: $focusedField, nextField: .fat)
                    MacroInputRow(label: "Fat", unit: "g", text: $fat, field: .fat, focusedField: $focusedField, nextField: nil)
                }

                Section {
                    DisclosureGroup("Additional Details", isExpanded: $showExtended) {
                        // Dynamic micronutrient rows — each one is a text field
                        ForEach(micronutrientTexts.indices, id: \.self) { index in
                            MacroInputRow(
                                label: micronutrientTexts[index].name,
                                unit: micronutrientTexts[index].unit,
                                text: $micronutrientTexts[index].text,
                                field: .micronutrient(micronutrientTexts[index].name),
                                focusedField: $focusedField,
                                nextField: index + 1 < micronutrientTexts.count
                                    ? .micronutrient(micronutrientTexts[index + 1].name)
                                    : .servingSize
                            )
                        }

                        // "Add Micronutrient" button — lets user add any nutrient
                        Button {
                            showAddMicro = true
                        } label: {
                            Label("Add Micronutrient", systemImage: "plus.circle")
                        }

                        HStack {
                            Text("Serving Size")
                            Spacer()
                            TextField("e.g. 170g", text: $servingSize)
                                .multilineTextAlignment(.trailing)
                                .focused($focusedField, equals: .servingSize)
                                .submitLabel(.done)
                                .onSubmit { focusedField = nil }
                        }
                    }
                }
            }
            .navigationTitle("Manual Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        // Primary: log + save to food bank
                        Button {
                            save(saveToFoodBank: true)
                        } label: {
                            Label("Add to Journal & Food Bank", systemImage: "plus.circle.fill")
                        }
                        // Secondary: log only
                        Button {
                            save(saveToFoodBank: false)
                        } label: {
                            Label("Add to Journal", systemImage: "plus.circle")
                        }
                    } label: {
                        Text("Add")
                            .fontWeight(.semibold)
                    }
                    .disabled(!isValid)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .onAppear {
                // Pre-fill form from OFF product if provided
                if let product = prefillProduct {
                    name = product.name
                    brand = product.brand ?? ""
                    calories = formatValue(product.caloriesPerServing)
                    protein = formatValue(product.proteinPerServing)
                    carbs = formatValue(product.carbsPerServing)
                    fat = formatValue(product.fatPerServing)
                    servingSize = product.servingSize ?? ""

                    // Pre-fill micronutrients from OFF data
                    // Replace default values with OFF values, add any extras
                    for i in micronutrientTexts.indices {
                        let microName = micronutrientTexts[i].name
                        if let offValue = product.micronutrients[microName] {
                            micronutrientTexts[i].text = formatValue(offValue.value)
                        }
                    }
                    // Add any OFF micronutrients not in the default set
                    let existingNames = Set(micronutrientTexts.map(\.name))
                    for (nutrientName, value) in product.micronutrients where !existingNames.contains(nutrientName) {
                        micronutrientTexts.append((name: nutrientName, unit: value.unit, text: formatValue(value.value)))
                    }

                    if !product.micronutrients.isEmpty {
                        showExtended = true
                    }

                    // Don't auto-focus name since it's already filled
                    focusedField = nil
                } else {
                    focusedField = .name
                }
            }
            .alert("Add Micronutrient", isPresented: $showAddMicro) {
                TextField("Name (e.g. Vitamin A)", text: $newMicroName)
                TextField("Unit (e.g. mg, mcg)", text: $newMicroUnit)
                Button("Add") {
                    let trimmed = newMicroName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        micronutrientTexts.append((name: trimmed, unit: newMicroUnit, text: ""))
                    }
                    newMicroName = ""
                    newMicroUnit = "g"
                }
                Button("Cancel", role: .cancel) {
                    newMicroName = ""
                    newMicroUnit = "g"
                }
            }
        }
    }

    /// Formats a Double for display in text fields — drops ".0" for whole numbers
    private func formatValue(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    private func save(saveToFoodBank: Bool) {
        guard let caloriesVal = Double(calories),
              let proteinVal = Double(protein),
              let carbsVal = Double(carbs),
              let fatVal = Double(fat)
        else { return }

        // Build the micronutrients dictionary from the dynamic text fields.
        // Only includes nutrients the user actually filled in.
        var micronutrients: [String: MicronutrientValue] = [:]
        for micro in micronutrientTexts {
            if let val = Double(micro.text) {
                micronutrients[micro.name] = MicronutrientValue(value: val, unit: micro.unit)
            }
        }

        let trimmedBrand = brand.trimmingCharacters(in: .whitespaces)

        let entry = NutritionEntry(
            name: name.trimmingCharacters(in: .whitespaces),
            mealType: mealType,
            scanMode: .manual,
            calories: caloriesVal,
            protein: proteinVal,
            carbs: carbsVal,
            fat: fatVal,
            micronutrients: micronutrients,
            servingSize: servingSize.isEmpty ? nil : servingSize,
            brand: trimmedBrand.isEmpty ? nil : trimmedBrand
        )
        nutritionStore.log(entry, to: defaultDate)

        // Optionally save to Food Bank for quick re-logging
        if saveToFoodBank {
            let savedFood = SavedFood(from: entry)
            modelContext.insert(savedFood)
            try? modelContext.save()
        }

        dismiss()
    }
}

// MARK: - MacroInputRow

private struct MacroInputRow: View {
    let label: String
    let unit: String
    @Binding var text: String
    let field: ManualEntryField
    @FocusState.Binding var focusedField: ManualEntryField?
    let nextField: ManualEntryField?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
                .submitLabel(nextField == nil ? .done : .next)
                .onSubmit {
                    focusedField = nextField
                }
                .frame(width: 80)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }
}

#Preview {
    ManualEntryView(defaultDate: .now)
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
}
