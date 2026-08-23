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

struct ManualEntryPrefill: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let brand: String?
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let micronutrients: [String: MicronutrientValue]
    let servingSize: String?

    init(
        name: String,
        brand: String?,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        micronutrients: [String: MicronutrientValue],
        servingSize: String?
    ) {
        self.name = name
        self.brand = brand
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.micronutrients = micronutrients
        self.servingSize = servingSize
    }

    init(product: OFFProduct) {
        self.init(
            name: product.name,
            brand: product.brand,
            calories: product.caloriesPerServing,
            protein: product.proteinPerServing,
            carbs: product.carbsPerServing,
            fat: product.fatPerServing,
            micronutrients: product.micronutrients,
            servingSize: product.servingSize
        )
    }

    init(entry: NutritionEntry) {
        self.init(
            name: entry.name,
            brand: entry.brand,
            calories: entry.calories,
            protein: entry.protein,
            carbs: entry.carbs,
            fat: entry.fat,
            micronutrients: entry.micronutrients,
            servingSize: entry.servingSize
        )
    }
}

struct ManualEntryView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(MealTimeSettings.self) private var mealTimeSettings
    @Environment(\.dismiss) private var dismiss

    let defaultDate: Date

    /// Optional food data to pre-fill the form with. OFF search and future
    /// providers use this so users can review/edit before saving.
    let prefill: ManualEntryPrefill?

    // Form state
    @State private var name = ""
    @State private var brand = ""
    @State private var mealType: MealType = .snack
    @State private var mealTypeWasEdited = false
    @State private var didApplyDefaultMealType = false
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
        self.prefill = nil
    }

    /// Initializer with an OFF product to pre-fill the form
    init(defaultDate: Date, prefillProduct: OFFProduct) {
        self.defaultDate = defaultDate
        self.prefill = ManualEntryPrefill(product: prefillProduct)
    }

    /// Initializer with a general prefill value for provider-backed or future sources.
    init(defaultDate: Date, prefill: ManualEntryPrefill) {
        self.defaultDate = defaultDate
        self.prefill = prefill
    }

    /// Initializer with a NutritionEntry that has not been inserted yet.
    init(defaultDate: Date, prefillEntry: NutritionEntry) {
        self.defaultDate = defaultDate
        self.prefill = ManualEntryPrefill(entry: prefillEntry)
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

                    Picker("Meal", selection: mealTypeBinding) {
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
                applyDefaultMealTypeIfNeeded()
                // Pre-fill form from search data if provided.
                if let prefill {
                    name = prefill.name
                    brand = prefill.brand ?? ""
                    calories = formatValue(prefill.calories)
                    protein = formatValue(prefill.protein)
                    carbs = formatValue(prefill.carbs)
                    fat = formatValue(prefill.fat)
                    servingSize = prefill.servingSize ?? ""

                    // Pre-fill micronutrients from the source data. Replace
                    // default values where names match, then add any extras.
                    for i in micronutrientTexts.indices {
                        let microName = micronutrientTexts[i].name
                        let sourceValue: MicronutrientValue?
                        if let known = KnownMicronutrients.find(microName) {
                            sourceValue = KnownMicronutrients.value(
                                in: prefill.micronutrients,
                                forID: known.id,
                                aliases: [microName]
                            )
                        } else {
                            sourceValue = prefill.micronutrients[microName]
                        }
                        if let sourceValue {
                            micronutrientTexts[i].text = formatValue(sourceValue.value)
                        }
                    }
                    // Add any source micronutrients not in the default set.
                    let existingIDs = Set(micronutrientTexts.map { KnownMicronutrients.normalize($0.name) })
                    for (nutrientName, value) in prefill.micronutrients where !existingIDs.contains(KnownMicronutrients.normalize(nutrientName)) {
                        micronutrientTexts.append((name: nutrientName, unit: value.unit, text: formatValue(value.value)))
                    }

                    if !prefill.micronutrients.isEmpty {
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

    private var mealTypeBinding: Binding<MealType> {
        Binding {
            mealType
        } set: { newValue in
            mealType = newValue
            mealTypeWasEdited = true
        }
    }

    private var mealTypeForLog: MealType {
        mealTypeWasEdited ? mealType : mealTimeSettings.mealType()
    }

    private func applyDefaultMealTypeIfNeeded() {
        guard !didApplyDefaultMealType else { return }
        mealType = mealTimeSettings.mealType()
        didApplyDefaultMealType = true
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
            mealType: mealTypeForLog,
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
            nutritionStore.addSavedFood(savedFood, mirrorReason: "manual_food_bank_save")
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
    let container = ModelContainer.preview
    ManualEntryView(defaultDate: .now)
        .modelContainer(container)
        .environment(NutritionStore(modelContext: container.mainContext))
        .environment(HealthKitService())
        .environment(MealTimeSettings())
}
