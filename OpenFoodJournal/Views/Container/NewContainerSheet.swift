// OpenFoodJournal — NewContainerSheet
// Lets the user start tracking a new food container.
// Step 1: Pick a food from the Food Bank (or enter manually)
// Step 2: Enter the serving size in grams + starting container weight
// AGPL-3.0 License

import SwiftUI
import SwiftData

private enum ContainerStartWeightMethod: String, CaseIterable, Identifiable {
    case total
    case tare

    var id: Self { self }

    var title: String {
        switch self {
        case .total: "Enter Weight"
        case .tare: "Use Tare"
        }
    }
}

private enum NewContainerField: Hashable {
    case gramsPerServing
    case totalWeight
    case tareWeight
    case loadedWeight
}

struct NewContainerSheet: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(TursoMirrorService.self) private var tursoMirror

    // ── SwiftData: all saved foods for the picker ─────────────────
    @Query(sort: \SavedFood.name) private var savedFoods: [SavedFood]

    // All containers, most recent first — used to derive "recently used" foods
    @Query(sort: \TrackedContainer.startDate, order: .reverse)
    private var allContainers: [TrackedContainer]

    // ── State ─────────────────────────────────────────────────────
    @State private var selectedFood: SavedFood?
    @State private var gramsPerServingText = ""
    @State private var weightMethod: ContainerStartWeightMethod = .total
    @State private var startWeightText = ""
    @State private var tareWeightText = ""
    @State private var loadedWeightText = ""
    @State private var searchText = ""
    @FocusState private var focusedField: NewContainerField?
    private let recentlyUsedLimit = 8

    init(preselectedFood: SavedFood? = nil) {
        _selectedFood = State(initialValue: preselectedFood)
        let gramMapping = preselectedFood?.servingMappings.first {
            $0.to.unit.lowercased() == "g"
        }
        _gramsPerServingText = State(initialValue: gramMapping.map {
            Self.formatInitialWeight($0.to.value)
        } ?? "")
    }

    // Foods sorted by recent container activity first, then alphabetically.
    private var sortedFoods: [SavedFood] {
        let lastTrackedDates = foodLastTrackedDates
        return savedFoods.sorted { lhs, rhs in
            let lhsDate = lastTrackedDates[lhs.id]
            let rhsDate = lastTrackedDates[rhs.id]

            switch (lhsDate, rhsDate) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate { return lhsDate > rhsDate }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var foodLastTrackedDates: [UUID: Date] {
        var result: [UUID: Date] = [:]
        for container in allContainers {
            guard let foodID = container.savedFoodID else { continue }
            let activityDate = container.completedDate ?? container.startDate
            if result[foodID].map({ activityDate > $0 }) ?? true {
                result[foodID] = activityDate
            }
        }
        return result
    }

    // Filtered foods based on search, preserving recent-use ordering.
    private var filteredFoods: [SavedFood] {
        searchText.isEmpty
            ? sortedFoods
            : sortedFoods.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Up to 8 most recently used foods in containers, de-duped by savedFoodID.
    /// Only includes foods that still exist in the Food Bank.
    private var recentlyUsedFoods: [SavedFood] {
        let savedFoodsByID = Dictionary(uniqueKeysWithValues: savedFoods.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var result: [SavedFood] = []
        for container in allContainers {
            guard let foodID = container.savedFoodID,
                  !seen.contains(foodID),
                  let food = savedFoodsByID[foodID] else { continue }
            seen.insert(foodID)
            result.append(food)
            if result.count >= recentlyUsedLimit { break }
        }
        return result
    }

    /// The latest completed end weight for the selected food, used as the next
    /// container's editable starting weight.
    private var selectedFoodLastEndWeight: Double? {
        guard let selectedFood else { return nil }
        return TrackedContainer.mostRecentEndWeight(
            for: selectedFood.id,
            in: allContainers
        )
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
                    Button("Done") { focusedField = nil }
                }
            }
            .onChange(of: selectedFood?.id, initial: true) {
                prefillStartWeightFromHistory()
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
                    // Recently used foods from past containers
                    if searchText.isEmpty, !recentlyUsedFoods.isEmpty {
                        Section("Recently Used") {
                            ForEach(recentlyUsedFoods) { food in
                                Button {
                                    selectFood(food)
                                } label: {
                                    SavedFoodRowView(food: food)
                                }
                                .tint(.primary)
                            }
                        }
                    }

                    // All foods section
                    Section(recentlyUsedFoods.isEmpty || !searchText.isEmpty ? "" : "All Foods") {
                        ForEach(filteredFoods) { food in
                            Button {
                                selectFood(food)
                            } label: {
                                SavedFoodRowView(food: food)
                            }
                            .tint(.primary)
                        }
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
                            .focused($focusedField, equals: .gramsPerServing)
                        Text("g")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.quaternary, in: .rect(cornerRadius: 12))
                }

                // Starting weight method
                VStack(alignment: .leading, spacing: 8) {
                    Text("Starting weight")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Enter the total directly, or calculate it from an empty container.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Starting weight method", selection: $weightMethod) {
                        ForEach(ContainerStartWeightMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Choose whether to enter the total weight or calculate it using an empty container")

                    switch weightMethod {
                    case .total:
                        totalWeightInput
                    case .tare:
                        tareWeightInputs
                    }
                }
                .animation(.spring(duration: 0.2), value: weightMethod)

                // Start tracking button
                Button {
                    guard let food = selectedFood,
                          let grams = Double(gramsPerServingText), grams > 0,
                          let weight = selectedStartWeight else { return }

                    let container = TrackedContainer.from(
                        food,
                        tareWeight: selectedTareWeight,
                        startWeight: weight,
                        gramsPerServing: grams
                    )
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
                    tursoMirror.scheduleMirror(reason: "container_created")

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

    // MARK: - Starting Weight

    private var totalWeightInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            weightField(
                title: "Container + food",
                explanation: "Place the container on a scale. Include the container itself.",
                placeholder: "e.g. 500",
                text: $startWeightText,
                field: .totalWeight
            )

            if let selectedFoodLastEndWeight {
                Text("Last end weight: \(formatWeight(selectedFoodLastEndWeight))g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    private var tareWeightInputs: some View {
        VStack(alignment: .leading, spacing: 12) {
            weightField(
                title: "Empty container",
                explanation: "Weigh the empty bowl, including any lid or accessories you will keep on it.",
                placeholder: "e.g. 350",
                text: $tareWeightText,
                field: .tareWeight
            )

            weightField(
                title: "Container + food",
                explanation: "Add the food, then weigh the same container again.",
                placeholder: "e.g. 500",
                text: $loadedWeightText,
                field: .loadedWeight
            )

            if let foodWeight = tareCalculation?.initialFoodWeight {
                HStack {
                    Label("Food added", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(formatWeight(foodWeight))g")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .padding()
                .glassEffect(in: .rect(cornerRadius: 20))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Food added \(formatWeight(foodWeight)) grams")
            } else if let tareValidationMessage {
                Label(tareValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(tareValidationMessage)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private func weightField(
        title: String,
        explanation: String,
        placeholder: String,
        text: Binding<String>,
        field: NewContainerField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField(placeholder, text: text)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .focused($focusedField, equals: field)
                    .accessibilityLabel(title)
                Text("g")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding()
            .background(.quaternary, in: .rect(cornerRadius: 12))
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
                tareWeightText = ""
                loadedWeightText = ""
                weightMethod = .total
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
        return selectedStartWeight != nil
    }

    private var tareCalculation: ContainerWeightCalculation? {
        guard let tareWeight = Double(tareWeightText),
              let loadedWeight = Double(loadedWeightText) else {
            return nil
        }
        return ContainerWeightCalculation(
            tareWeight: tareWeight,
            initialGrossWeight: loadedWeight,
            endingGrossWeight: nil
        )
    }

    private var selectedStartWeight: Double? {
        switch weightMethod {
        case .total:
            guard let weight = Double(startWeightText) else { return nil }
            let calculation = ContainerWeightCalculation(
                tareWeight: nil,
                initialGrossWeight: weight,
                endingGrossWeight: nil
            )
            return calculation.isValidStart ? weight : nil
        case .tare:
            guard let calculation = tareCalculation, calculation.isValidStart else { return nil }
            return calculation.initialGrossWeight
        }
    }

    private var selectedTareWeight: Double? {
        guard weightMethod == .tare,
              let calculation = tareCalculation,
              calculation.isValidStart else {
            return nil
        }
        return calculation.tareWeight
    }

    private var tareValidationMessage: String? {
        guard !tareWeightText.isEmpty || !loadedWeightText.isEmpty else { return nil }
        guard let tareWeight = Double(tareWeightText),
              tareWeight.isFinite,
              tareWeight > 0 else {
            return "Enter a positive empty-container weight."
        }
        guard let loadedWeight = Double(loadedWeightText),
              loadedWeight.isFinite,
              loadedWeight > 0 else {
            return "Enter the container-and-food weight."
        }
        guard loadedWeight > tareWeight else {
            return "Container + food must be heavier than the empty container."
        }
        return nil
    }

    // MARK: - Helpers

    /// Selects a food and pre-fills grams per serving from its mappings if available
    private func selectFood(_ food: SavedFood) {
        selectedFood = food
        if let mapping = food.servingMappings.first(where: { $0.to.unit.lowercased() == "g" }) {
            gramsPerServingText = String(format: "%.0f", mapping.to.value)
        }
    }

    private func prefillStartWeightFromHistory() {
        guard selectedFood != nil else {
            startWeightText = ""
            tareWeightText = ""
            loadedWeightText = ""
            return
        }
        startWeightText = selectedFoodLastEndWeight.map(formatWeight) ?? ""
    }

    private func formatWeight(_ weight: Double) -> String {
        Self.formatInitialWeight(weight)
    }

    private static func formatInitialWeight(_ weight: Double) -> String {
        var text = String(format: "%.3f", weight)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }
}
