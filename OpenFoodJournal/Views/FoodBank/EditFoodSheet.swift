// OpenFoodJournal — EditFoodSheet
// Allows editing a SavedFood's name, brand, and core macros.
// Presented from FoodBankView via swipe action or context menu.
// Changes are saved to SwiftData and synced to Turso.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct EditFoodSheet: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService

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
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                // Identity — name and brand
                Section("Identity") {
                    TextField("Food name", text: $name)
                    TextField("Brand (optional)", text: $brand)
                }

                // Core macros
                Section("Nutrition (per serving)") {
                    MacroField(label: "Calories", unit: "kcal", text: $calories)
                    MacroField(label: "Protein", unit: "g", text: $protein)
                    MacroField(label: "Carbs", unit: "g", text: $carbs)
                    MacroField(label: "Fat", unit: "g", text: $fat)
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
                    Task { try? await syncService.deleteFood(id: foodId) }
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
            }
        }
    }

    // MARK: - Save Changes

    /// Apply buffered text field values back to the SwiftData model and sync
    private func saveChanges() {
        food.name = name.trimmingCharacters(in: .whitespaces)
        food.brand = brand.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : brand.trimmingCharacters(in: .whitespaces)
        food.calories = Double(calories) ?? food.calories
        food.protein = Double(protein) ?? food.protein
        food.carbs = Double(carbs) ?? food.carbs
        food.fat = Double(fat) ?? food.fat
        food.servingSize = servingSize.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : servingSize.trimmingCharacters(in: .whitespaces)

        try? modelContext.save()

        // Sync updated food to Turso
        Task { try? await syncService.updateFood(food) }
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
