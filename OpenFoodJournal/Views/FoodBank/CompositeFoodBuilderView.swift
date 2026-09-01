// OpenFoodJournal — CompositeFoodBuilderView
// Creates or edits Food Bank composites from snapshot copies of saved foods.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct CompositeFoodBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(TursoMirrorService.self) private var tursoMirror

    private let food: SavedFood?

    @State private var name: String
    @State private var brand: String
    @State private var ingredients: [CompositeIngredientSnapshot]
    @State private var showingIngredientPicker = false
    @State private var editingIngredient: CompositeIngredientSnapshot?
    @State private var showDeleteConfirm = false

    init(food: SavedFood? = nil) {
        self.food = food
        _name = State(initialValue: food?.name ?? "")
        _brand = State(initialValue: food?.brand ?? "")
        _ingredients = State(initialValue: food?.compositeIngredients ?? [])
    }

    private var isEditing: Bool {
        food != nil
    }

    private var totals: CompositeNutritionTotals {
        SavedFood.compositeTotals(for: ingredients)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !ingredients.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                nutritionSummarySection
                ingredientsSection

                if isEditing {
                    deleteSection
                }
            }
            .navigationTitle(isEditing ? "Edit Composite" : "Composite Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveComposite()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showingIngredientPicker) {
                CompositeIngredientPickerView(excludedFoodID: food?.id) { selectedFood in
                    ingredients.append(CompositeIngredientSnapshot(food: selectedFood))
                }
            }
            .sheet(item: $editingIngredient) { ingredient in
                CompositeIngredientPortionSheet(ingredient: ingredient) { updated in
                    if let index = ingredients.firstIndex(where: { $0.id == updated.id }) {
                        ingredients[index] = updated
                    }
                }
            }
            .confirmationDialog(
                "Delete \(name.isEmpty ? "Composite Food" : name)?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let food {
                        modelContext.delete(food)
                        try? modelContext.save()
                        tursoMirror.scheduleMirror(reason: "composite_deleted")
                    }
                    dismiss()
                }
            } message: {
                Text("This composite will be removed from your Food Bank. Journal entries that used it won't be affected.")
            }
        }
    }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Composite name", text: $name)
            TextField("Brand or note (optional)", text: $brand)
        }
    }

    private var nutritionSummarySection: some View {
        Section("Nutrition for 1 Portion") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                CompositeMacroCard(label: "Calories", value: totals.calories, unit: "cal", color: .orange)
                CompositeMacroCard(label: "Protein", value: totals.protein, unit: "g", color: .blue)
                CompositeMacroCard(label: "Carbs", value: totals.carbs, unit: "g", color: .green)
                CompositeMacroCard(label: "Fat", value: totals.fat, unit: "g", color: .yellow)
            }
            .padding(.vertical, 4)
        }
    }

    private var ingredientsSection: some View {
        Section {
            if ingredients.isEmpty {
                Text("Add saved foods to build one repeatable portion.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ingredients) { ingredient in
                    Button {
                        editingIngredient = ingredient
                    } label: {
                        CompositeIngredientRow(ingredient: ingredient)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    ingredients.remove(atOffsets: offsets)
                }
            }

            Button {
                showingIngredientPicker = true
            } label: {
                Label("Add Ingredient", systemImage: "plus.circle")
            }
        } header: {
            Text("Ingredients")
        } footer: {
            Text("Ingredients are copied snapshots. Later edits to the source foods will not change this composite.")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete from Food Bank", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func saveComposite() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedBrand = brand.trimmingCharacters(in: .whitespaces)

        if let food {
            food.name = trimmedName
            food.brand = trimmedBrand.isEmpty ? nil : trimmedBrand
            food.kind = .composite
            food.compositeIngredients = ingredients
            food.refreshCompositeNutrition()
        } else {
            let totals = SavedFood.compositeTotals(for: ingredients)
            let composite = SavedFood(
                name: trimmedName,
                brand: trimmedBrand.isEmpty ? nil : trimmedBrand,
                calories: totals.calories,
                protein: totals.protein,
                carbs: totals.carbs,
                fat: totals.fat,
                micronutrients: totals.micronutrients,
                servingSize: "1 portion",
                servingQuantity: 1,
                servingUnit: "portion",
                originalScanMode: .manual,
                kind: .composite,
                compositeIngredients: ingredients
            )
            composite.refreshCompositeNutrition()
            nutritionStore.addSavedFood(composite, mirrorReason: "composite_created")
        }

        if isEditing {
            nutritionStore.saveChanges(mirrorReason: "composite_updated")
        }
        dismiss()
    }
}

private struct CompositeIngredientPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SavedFood.createdAt, order: .reverse)
    private var allFoods: [SavedFood]

    let excludedFoodID: UUID?
    let onSelect: (SavedFood) -> Void

    @State private var searchText = ""

    private var filteredFoods: [SavedFood] {
        allFoods
            .filter { food in
                food.id != excludedFoodID && matchesSearch(food)
            }
            .sorted { lhs, rhs in
                lhs.lastUsedAt > rhs.lastUsedAt
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredFoods.isEmpty {
                    ContentUnavailableView {
                        Label("No Foods", systemImage: "refrigerator")
                    } description: {
                        Text(searchText.isEmpty ? "Save foods before building a composite." : "Try another food name or brand.")
                    }
                } else {
                    List {
                        ForEach(filteredFoods) { food in
                            Button {
                                onSelect(food)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    SavedFoodRowView(food: food)
                                    if food.kind == .composite {
                                        Label("Composite snapshot", systemImage: "square.stack.3d.up")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, 56)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Add Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search saved foods")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func matchesSearch(_ food: SavedFood) -> Bool {
        guard !searchText.isEmpty else { return true }
        return food.name.localizedCaseInsensitiveContains(searchText) ||
            (food.brand?.localizedCaseInsensitiveContains(searchText) ?? false)
    }
}

private struct CompositeIngredientPortionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let ingredient: CompositeIngredientSnapshot
    let onSave: (CompositeIngredientSnapshot) -> Void

    @State private var quantityText: String
    @State private var selectedUnit: String

    init(
        ingredient: CompositeIngredientSnapshot,
        onSave: @escaping (CompositeIngredientSnapshot) -> Void
    ) {
        self.ingredient = ingredient
        self.onSave = onSave
        _quantityText = State(initialValue: CompositeFoodFormat.quantity(ingredient.selectedQuantity))
        _selectedUnit = State(initialValue: ingredient.selectedUnit)
    }

    private var quantity: Double {
        Double(quantityText) ?? ingredient.selectedQuantity
    }

    private var availableUnits: [String] {
        ingredient.availableUnits
    }

    private var editedIngredient: CompositeIngredientSnapshot {
        var updated = ingredient
        updated.selectedQuantity = quantity
        updated.selectedUnit = selectedUnit
        return updated
    }

    private var totals: CompositeNutritionTotals {
        editedIngredient.scaledNutrition
    }

    private var isValid: Bool {
        guard let value = Double(quantityText) else { return false }
        return value > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ingredient") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let brand = ingredient.brand, !brand.isEmpty {
                            Text(brand)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(ingredient.name)
                            .font(.headline)
                        if let servingSize = ingredient.servingSize {
                            Text("Base serving: \(servingSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Portion") {
                    HStack {
                        Text("Quantity")
                        Spacer()
                        TextField("Amount", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
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

                Section("Scaled Nutrition") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        CompositeMacroCard(label: "Calories", value: totals.calories, unit: "cal", color: .orange)
                        CompositeMacroCard(label: "Protein", value: totals.protein, unit: "g", color: .blue)
                        CompositeMacroCard(label: "Carbs", value: totals.carbs, unit: "g", color: .green)
                        CompositeMacroCard(label: "Fat", value: totals.fat, unit: "g", color: .yellow)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Ingredient Portion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(editedIngredient)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
    }
}

private struct CompositeIngredientRow: View {
    let ingredient: CompositeIngredientSnapshot

    private var totals: CompositeNutritionTotals {
        ingredient.scaledNutrition
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .center, spacing: 2) {
                Text("\(Int(totals.calories))")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .ofjNumericTextTransition(value: totals.calories)
                Text("cal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                if let brand = ingredient.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(ingredient.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("\(CompositeFoodFormat.quantity(ingredient.selectedQuantity)) \(ingredient.selectedUnit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .ofjNumericTextTransition(value: ingredient.selectedQuantity)

                HStack(spacing: 6) {
                    MacroChip(value: totals.protein, color: .blue, label: "P")
                    MacroChip(value: totals.carbs, color: .green, label: "C")
                    MacroChip(value: totals.fat, color: .yellow, label: "F")
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct CompositeMacroCard: View {
    let label: String
    let value: Double
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(CompositeFoodFormat.number(value))
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .ofjNumericTextTransition(value: value)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 12))
    }
}

private enum CompositeFoodFormat {
    static func quantity(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
    }

    static func number(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}

#Preview {
    CompositeFoodBuilderView()
        .modelContainer(ModelContainer.preview)
}
