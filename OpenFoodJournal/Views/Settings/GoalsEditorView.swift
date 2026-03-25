// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI

struct GoalsEditorView: View {
    @Environment(UserGoals.self) private var goals
    @Environment(\.dismiss) private var dismiss

    // Local state mirrors goals so changes are buffered until Save
    @State private var calories: Double = 0
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0

    var body: some View {
        Form {
            Section("Daily Targets") {
                GoalRow(label: "Calories", unit: "kcal", value: $calories)
                GoalRow(label: "Protein", unit: "g", value: $protein)
                GoalRow(label: "Carbs", unit: "g", value: $carbs)
                GoalRow(label: "Fat", unit: "g", value: $fat)
            }

            Section {
                HStack {
                    let totalFromMacros = protein * 4 + carbs * 4 + fat * 9
                    Text("Macro-derived calories")
                    Spacer()
                    Text("\(Int(totalFromMacros)) kcal")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Protein & carbs = 4 kcal/g · Fat = 9 kcal/g (Atwater system). Use this as a sanity check against your calorie goal. These are general factors — individual needs vary. Consult a healthcare professional for personalized guidance.")
            }
        }
        .navigationTitle("Daily Goals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    goals.dailyCalories = calories
                    goals.dailyProtein = protein
                    goals.dailyCarbs = carbs
                    goals.dailyFat = fat

                    dismiss()
                }
                .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .onAppear {
            calories = goals.dailyCalories
            protein = goals.dailyProtein
            carbs = goals.dailyCarbs
            fat = goals.dailyFat
        }
    }
}

private struct GoalRow: View {
    let label: String
    let unit: String
    @Binding var value: Double

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: 80)
                .onChange(of: text) { _, newVal in
                    if let d = Double(newVal) { value = d }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { text = String(format: "%.0f", value) }
                }
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .onAppear { text = String(format: "%.0f", value) }
    }
}

#Preview {
    NavigationStack {
        GoalsEditorView()
            .environment(UserGoals())
    }
}
