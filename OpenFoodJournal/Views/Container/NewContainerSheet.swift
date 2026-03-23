// OpenFoodJournal — NewContainerSheet
// Lets the user start tracking a new food container.
// Step 1: Pick a food from the Food Bank (or enter manually)
// Step 2: Enter the serving size in grams + starting container weight
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct NewContainerSheet: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService

    // ── SwiftData: all saved foods for the picker ─────────────────
    @Query(sort: \SavedFood.name) private var savedFoods: [SavedFood]

    // ── State ─────────────────────────────────────────────────────
    @State private var selectedFood: SavedFood?
    @State private var gramsPerServingText = ""
    @State private var startWeightText = ""
    @State private var searchText = ""
    @FocusState private var focusedField: Bool

    // Filtered foods based on search
    private var filteredFoods: [SavedFood] {
        searchText.isEmpty
            ? savedFoods
            : savedFoods.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if selectedFood == nil {
                    // Step 1: Pick a food
                    foodPicker
                } else {
                    // Step 2: Enter weight details
                    weightForm
                }
            }
            .navigationTitle(selectedFood == nil ? "Pick a Food" : "Start Tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = false }
                }
            }
        }
    }

    // MARK: - Step 1: Food Picker

    /// Searchable list of saved foods to pick for container tracking
    private var foodPicker: some View {
        Group {
            if savedFoods.isEmpty {
                // No saved foods — can't track a container without a food reference
                ContentUnavailableView {
                    Label("No Saved Foods", systemImage: "refrigerator")
                } description: {
                    Text("Save a food from a scan or manual entry first, then you can track its container.")
                }
            } else {
                List {
                    ForEach(filteredFoods) { food in
                        Button {
                            selectedFood = food
                            // Pre-fill grams per serving if the food has serving mappings with grams
                            if let mapping = food.servingMappings.first(where: { $0.to.unit.lowercased() == "g" }) {
                                gramsPerServingText = String(format: "%.0f", mapping.to.value)
                            }
                        } label: {
                            SavedFoodRowView(food: food)
                        }
                        .tint(.primary)
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: "Search foods")
            }
        }
    }

    // MARK: - Step 2: Weight Form

    /// Form for entering grams per serving and starting container weight
    private var weightForm: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Selected food summary
                if let food = selectedFood {
                    selectedFoodCard(food)
                }

                // Grams per serving input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Grams per serving")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("How many grams is one serving? Check the nutrition label.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("e.g. 39", text: $gramsPerServingText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .focused($focusedField)
                        Text("g")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.quaternary, in: .rect(cornerRadius: 12))
                }

                // Starting weight input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Container weight")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Place the full container on a scale. Include the container itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("e.g. 500", text: $startWeightText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .focused($focusedField)
                        Text("g")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.quaternary, in: .rect(cornerRadius: 12))
                }

                // Start tracking button
                Button {
                    guard let food = selectedFood,
                          let grams = Double(gramsPerServingText), grams > 0,
                          let weight = Double(startWeightText), weight > 0 else { return }

                    let container = TrackedContainer.from(food, startWeight: weight, gramsPerServing: grams)
                    modelContext.insert(container)

                    // Auto-save the grams-per-serving mapping back to the food
                    // so it pre-fills next time this food is used in a container.
                    let hasGramMapping = food.servingMappings.contains { $0.to.unit.lowercased() == "g" }
                    if !hasGramMapping {
                        let unit = food.servingUnit ?? "serving"
                        let qty = food.servingQuantity ?? 1.0
                        let mapping = ServingMapping(
                            from: ServingAmount(value: qty, unit: unit),
                            to: ServingAmount(value: grams, unit: "g")
                        )
                        food.servingMappings.append(mapping)
                    }

                    try? modelContext.save()

                    // Fire-and-forget sync: create container + update food mappings on server
                    let sync = syncService
                    Task {
                        try? await sync.createContainer(container)
                        if !hasGramMapping { try? await sync.updateFood(food) }
                    }

                    dismiss()
                } label: {
                    Label("Start Tracking", systemImage: "scalemass")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isFormValid)
            }
            .padding()
        }
    }

    // MARK: - Selected Food Card

    /// Shows a compact summary of the selected food
    private func selectedFoodCard(_ food: SavedFood) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.name)
                    .font(.headline)
                if let brand = food.brand {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Allow changing food selection
            Button("Change") {
                selectedFood = nil
                gramsPerServingText = ""
                startWeightText = ""
            }
            .font(.caption)
        }
        .padding()
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        guard selectedFood != nil else { return false }
        guard let grams = Double(gramsPerServingText), grams > 0 else { return false }
        guard let weight = Double(startWeightText), weight > 0 else { return false }
        return true
    }
}
