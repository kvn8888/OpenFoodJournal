// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

// Shared focus field enum — fileprivate so MacroInputRow can access it
fileprivate enum ManualEntryField: Hashable {
    case name, calories, protein, carbs, fat, fiber, sugar, sodium, servingSize
}

struct ManualEntryView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(\.dismiss) private var dismiss

    let defaultDate: Date

    // Form state
    @State private var name = ""
    @State private var mealType: MealType = .snack
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var showExtended = false

    // Extended
    @State private var fiber = ""
    @State private var sugar = ""
    @State private var sodium = ""
    @State private var servingSize = ""

    @FocusState private var focusedField: ManualEntryField?

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
                        MacroInputRow(label: "Fiber", unit: "g", text: $fiber, field: .fiber, focusedField: $focusedField, nextField: .sugar)
                        MacroInputRow(label: "Sugar", unit: "g", text: $sugar, field: .sugar, focusedField: $focusedField, nextField: .sodium)
                        MacroInputRow(label: "Sodium", unit: "mg", text: $sodium, field: .sodium, focusedField: $focusedField, nextField: .servingSize)

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
                    Button("Add") { save() }
                        .disabled(!isValid)
                        .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .onAppear {
                focusedField = .name
            }
        }
    }

    private func save() {
        guard let caloriesVal = Double(calories),
              let proteinVal = Double(protein),
              let carbsVal = Double(carbs),
              let fatVal = Double(fat)
        else { return }

        let entry = NutritionEntry(
            name: name.trimmingCharacters(in: .whitespaces),
            mealType: mealType,
            scanMode: .manual,
            calories: caloriesVal,
            protein: proteinVal,
            carbs: carbsVal,
            fat: fatVal,
            fiber: Double(fiber),
            sugar: Double(sugar),
            sodium: Double(sodium),
            servingSize: servingSize.isEmpty ? nil : servingSize
        )
        nutritionStore.log(entry, to: defaultDate)
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
