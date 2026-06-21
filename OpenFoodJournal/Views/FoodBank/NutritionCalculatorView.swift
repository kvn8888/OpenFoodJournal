// OpenFoodJournal — NutritionCalculatorView
// Runtime-configurable restaurant/brand nutrition calculators.
// AGPL-3.0 License

import SwiftUI
import SwiftData
import PhotosUI

struct NutritionCalculatorLibraryView: View {
    @Environment(\.dismiss) private var dismiss

    let logDate: Date

    @Query(sort: \SavedFood.lastUsedAt, order: .reverse)
    private var allFoods: [SavedFood]

    @State private var searchText = ""
    @State private var selectedCalculator: SavedFood?
    @State private var calculatorToEdit: SavedFood?
    @State private var showNewCalculator = false

    private var calculators: [SavedFood] {
        allFoods
            .filter { $0.kind == .calculator && matchesSearch($0) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if calculators.isEmpty {
                    emptyState
                } else {
                    calculatorList
                }
            }
            .navigationTitle("Nutrition Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search restaurants")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showNewCalculator = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewCalculator) {
                NutritionCalculatorEditorView()
            }
            .sheet(item: $calculatorToEdit) { calculator in
                NutritionCalculatorEditorView(calculator: calculator)
            }
            .sheet(item: $selectedCalculator) { calculator in
                NutritionCalculatorBuildView(calculator: calculator, logDate: logDate)
            }
        }
    }

    private var calculatorList: some View {
        List {
            ForEach(calculators) { calculator in
                Button {
                    selectedCalculator = calculator
                } label: {
                    SavedFoodRowView(food: calculator)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button {
                        calculatorToEdit = calculator
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(searchText.isEmpty ? "No Calculators" : "No Results", systemImage: "slider.horizontal.3")
        } description: {
            Text(searchText.isEmpty
                 ? "Add a restaurant or brand calculator, then build custom meals from runtime portion options."
                 : "Try another restaurant or brand.")
        } actions: {
            Button {
                showNewCalculator = true
            } label: {
                Label("Add Calculator", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func matchesSearch(_ food: SavedFood) -> Bool {
        guard !searchText.isEmpty else { return true }
        return food.name.localizedCaseInsensitiveContains(searchText) ||
            (food.brand?.localizedCaseInsensitiveContains(searchText) ?? false)
    }
}

struct NutritionCalculatorEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ScanService.self) private var scanService
    @Environment(TursoMirrorService.self) private var tursoMirror
    @AppStorage("scan.useProModel") private var useProModel: Bool = false

    private let calculator: SavedFood?

    @State private var name: String
    @State private var brand: String
    @State private var groups: [CalculatorGroup]
    @State private var presets: [CalculatorPreset]
    @State private var editingGroup: CalculatorGroup?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var stagedRows: [CalculatorOCRRow] = []
    @State private var ocrError: String?
    @State private var isImportingOCR = false
    @State private var showDeleteConfirm = false

    init(calculator: SavedFood? = nil) {
        self.calculator = calculator
        _name = State(initialValue: calculator?.name ?? "")
        _brand = State(initialValue: calculator?.brand ?? "")
        _groups = State(initialValue: calculator?.calculatorGroups ?? [])
        _presets = State(initialValue: calculator?.calculatorPresets ?? [])
    }

    private var isEditing: Bool { calculator != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                ocrSection
                groupsSection
                if isEditing {
                    deleteSection
                }
            }
            .navigationTitle(isEditing ? "Edit Calculator" : "New Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCalculator()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
            .sheet(item: $editingGroup) { group in
                CalculatorGroupEditorSheet(group: group) { updated in
                    if let index = groups.firstIndex(where: { $0.id == updated.id }) {
                        groups[index] = updated
                    } else {
                        groups.append(updated)
                    }
                }
            }
            .confirmationDialog(
                "Delete Calculator?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let calculator {
                        modelContext.delete(calculator)
                        try? modelContext.save()
                        tursoMirror.scheduleMirror(reason: "nutrition_calculator_deleted")
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Logged journal entries from this calculator will not change.")
            }
        }
    }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Restaurant or brand", text: $name)
            TextField("Default meal name or note (optional)", text: $brand)
        }
    }

    private var ocrSection: some View {
        Section {
            PhotosPicker(
                selection: $selectedPhotoItems,
                maxSelectionCount: ScanService.maxImagesPerScan,
                matching: .images
            ) {
                Label("Choose Screenshot or Photo", systemImage: "photo.on.rectangle")
            }

            Button {
                Task { await extractOCRRows() }
            } label: {
                if isImportingOCR {
                    Label("Reading Nutrition Rows", systemImage: "wand.and.sparkles")
                } else {
                    Label("Extract Rows with Gemini", systemImage: "wand.and.sparkles")
                }
            }
            .disabled(selectedPhotoItems.isEmpty || isImportingOCR)

            if let ocrError {
                Text(ocrError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !stagedRows.isEmpty {
                ForEach(stagedRows) { row in
                    CalculatorOCRRowView(row: row)
                }

                Button {
                    importStagedRows()
                } label: {
                    Label("Import Reviewed Rows", systemImage: "tray.and.arrow.down")
                }
            }
        } header: {
            Text("Gemini OCR Import")
        } footer: {
            Text("Extracted rows are staged here first. Importing creates editable groups, ingredients, and runtime portion labels.")
        }
    }

    private var groupsSection: some View {
        Section {
            if groups.isEmpty {
                Text("Add groups like Rice, Protein, Toppings, or import rows from screenshots.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { group in
                    Button {
                        editingGroup = group
                    } label: {
                        CalculatorGroupRow(group: group)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    groups.remove(atOffsets: offsets)
                }
            }

            Button {
                editingGroup = CalculatorGroup(
                    name: "",
                    isRequired: false,
                    selectionRule: .multiple
                )
            } label: {
                Label("Add Group", systemImage: "plus.circle")
            }
        } header: {
            Text("Groups")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete Calculator", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func extractOCRRows() async {
        isImportingOCR = true
        ocrError = nil
        defer { isImportingOCR = false }

        var images: [UIImage] = []
        for item in selectedPhotoItems {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            images.append(image)
        }

        do {
            stagedRows = try await scanService.extractCalculatorRows(from: images, useProModel: useProModel)
            if stagedRows.isEmpty {
                ocrError = "No usable rows were found. Try a clearer screenshot."
            }
        } catch {
            ocrError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func importStagedRows() {
        for row in stagedRows {
            let groupName = row.groupName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Imported"
            let ingredientName = row.ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
            let portionLabel = row.portionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ingredientName.isEmpty, !portionLabel.isEmpty else { continue }

            let portion = CalculatorPortionOption(
                label: portionLabel,
                calories: row.calories,
                protein: row.protein,
                carbs: row.carbs,
                fat: row.fat,
                micronutrients: row.micronutrients
            )

            let groupIndex = groups.firstIndex {
                $0.name.caseInsensitiveCompare(groupName) == .orderedSame
            } ?? {
                groups.append(CalculatorGroup(name: groupName, selectionRule: .multiple))
                return groups.count - 1
            }()

            let ingredientIndex = groups[groupIndex].ingredients.firstIndex {
                $0.name.caseInsensitiveCompare(ingredientName) == .orderedSame
            } ?? {
                groups[groupIndex].ingredients.append(CalculatorIngredient(name: ingredientName))
                return groups[groupIndex].ingredients.count - 1
            }()

            if !groups[groupIndex].ingredients[ingredientIndex].portions.contains(where: {
                $0.label.caseInsensitiveCompare(portionLabel) == .orderedSame
            }) {
                groups[groupIndex].ingredients[ingredientIndex].portions.append(portion)
            }
        }

        stagedRows = []
        selectedPhotoItems = []
    }

    private func saveCalculator() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)

        if let calculator {
            calculator.name = trimmedName
            calculator.brand = trimmedBrand.nilIfEmpty
            calculator.kind = .calculator
            calculator.calculatorGroups = groups
            calculator.calculatorPresets = presets
            calculator.refreshCalculatorNutrition()
        } else {
            let calculator = SavedFood(
                name: trimmedName,
                brand: trimmedBrand.nilIfEmpty,
                calories: 0,
                protein: 0,
                carbs: 0,
                fat: 0,
                servingSize: "\(groups.count) group\(groups.count == 1 ? "" : "s")",
                servingQuantity: 1,
                servingUnit: "build",
                kind: .calculator,
                calculatorGroups: groups,
                calculatorPresets: presets
            )
            calculator.refreshCalculatorNutrition()
            modelContext.insert(calculator)
        }

        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: isEditing ? "nutrition_calculator_updated" : "nutrition_calculator_created")
        dismiss()
    }
}

struct NutritionCalculatorBuildView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(HealthKitService.self) private var healthKit
    @Environment(TursoMirrorService.self) private var tursoMirror
    @AppStorage("healthkit.enabled") private var healthKitEnabled: Bool = false

    @Bindable var calculator: SavedFood
    let logDate: Date

    @State private var mealType: MealType = .snack
    @State private var buildName: String
    @State private var selections: [CalculatorSelection] = []
    @State private var presetName = ""
    @State private var showPresetPrompt = false
    @State private var presetWarning: String?

    init(calculator: SavedFood, logDate: Date) {
        self.calculator = calculator
        self.logDate = logDate
        _buildName = State(initialValue: calculator.name)
    }

    private var totals: CompositeNutritionTotals {
        SavedFood.calculatorTotals(for: calculator.calculatorGroups, selections: selections)
    }

    private var missingRequiredGroups: [CalculatorGroup] {
        calculator.calculatorGroups.filter { group in
            group.isRequired && !selections.contains(where: { $0.groupID == group.id })
        }
    }

    private var canLog: Bool {
        !selections.isEmpty &&
        missingRequiredGroups.isEmpty &&
        !buildName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                if !calculator.calculatorPresets.isEmpty {
                    presetsSection
                }
                groupsSection
                quantitiesSection
                actionsSection
            }
            .navigationTitle(calculator.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Save Build Preset", isPresented: $showPresetPrompt) {
                TextField("Preset name", text: $presetName)
                Button("Save") { savePreset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Presets store selections, not nutrition totals, so future logs use the latest calculator values.")
            }
            .alert("Preset Needs Review", isPresented: Binding(
                get: { presetWarning != nil },
                set: { if !$0 { presetWarning = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(presetWarning ?? "")
            }
        }
    }

    private var summarySection: some View {
        Section("Build") {
            TextField("Logged meal name", text: $buildName)

            Picker("Meal", selection: $mealType) {
                ForEach(MealType.allCases) { meal in
                    Text(meal.rawValue.capitalized).tag(meal)
                }
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                CalculatorMacroCard(label: "Calories", value: totals.calories, unit: "cal", color: .orange)
                CalculatorMacroCard(label: "Protein", value: totals.protein, unit: "g", color: .blue)
                CalculatorMacroCard(label: "Carbs", value: totals.carbs, unit: "g", color: .green)
                CalculatorMacroCard(label: "Fat", value: totals.fat, unit: "g", color: .yellow)
            }
        }
    }

    private var presetsSection: some View {
        Section("Presets") {
            ForEach(calculator.calculatorPresets.sorted { $0.lastUsedAt > $1.lastUsedAt }) { preset in
                Button {
                    applyPreset(preset)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.name)
                                .fontWeight(.medium)
                            Text("\(preset.selections.count) selection\(preset.selections.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var groupsSection: some View {
        ForEach(calculator.calculatorGroups) { group in
            Section {
                if group.ingredients.isEmpty {
                    Text("No ingredients in this group.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if group.selectionRule == .single {
                    Picker(group.name, selection: singleSelectionBinding(for: group)) {
                        if !group.isRequired {
                            Text("None").tag("")
                        }
                        ForEach(group.ingredients) { ingredient in
                            ForEach(ingredient.portions) { portion in
                                Text("\(ingredient.name) — \(portion.label)")
                                    .tag(selectionKey(groupID: group.id, ingredientID: ingredient.id, portionID: portion.id))
                            }
                        }
                    }
                } else {
                    ForEach(group.ingredients) { ingredient in
                        Picker(ingredient.name, selection: multipleSelectionBinding(group: group, ingredient: ingredient)) {
                            Text("None").tag("")
                            ForEach(ingredient.portions) { portion in
                                Text(portion.label)
                                    .tag(selectionKey(groupID: group.id, ingredientID: ingredient.id, portionID: portion.id))
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(group.name)
                    if group.isRequired {
                        Text("Required")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var quantitiesSection: some View {
        if !selections.isEmpty {
            Section {
                ForEach($selections) { $selection in
                    Group {
                        if let resolved = resolvedSelection(selection) {
                            VStack(alignment: .leading, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(resolved.ingredient.name)
                                        .fontWeight(.medium)
                                    Text("\(resolved.group.name) · \(resolved.portion.label)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Stepper(
                                    value: quantityBinding(for: $selection),
                                    in: 0.25...20,
                                    step: 0.25
                                ) {
                                    Text("\(CalculatorFormat.number(selection.quantity))x")
                                        .monospacedDigit()
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } header: {
                Text("Quantities")
            } footer: {
                Text("Use quantities for runtime adjustments like double portions or multiple scoops without changing the saved calculator.")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                logBuild()
            } label: {
                Label("Add to Journal", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canLog)

            Button {
                presetName = buildName
                showPresetPrompt = true
            } label: {
                Label("Save Build Preset", systemImage: "bookmark")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(selections.isEmpty)
        } footer: {
            if !missingRequiredGroups.isEmpty {
                Text("Choose an option for: \(missingRequiredGroups.map(\.name).joined(separator: ", ")).")
            }
        }
    }

    private func singleSelectionBinding(for group: CalculatorGroup) -> Binding<String> {
        Binding {
            guard let selection = selections.first(where: { $0.groupID == group.id }) else { return "" }
            return selectionKey(groupID: selection.groupID, ingredientID: selection.ingredientID, portionID: selection.portionID)
        } set: { newValue in
            selections.removeAll { $0.groupID == group.id }
            if let selection = selection(from: newValue) {
                selections.append(selection)
            }
        }
    }

    private func multipleSelectionBinding(group: CalculatorGroup, ingredient: CalculatorIngredient) -> Binding<String> {
        Binding {
            guard let selection = selections.first(where: { $0.groupID == group.id && $0.ingredientID == ingredient.id }) else {
                return ""
            }
            return selectionKey(groupID: selection.groupID, ingredientID: selection.ingredientID, portionID: selection.portionID)
        } set: { newValue in
            selections.removeAll { $0.groupID == group.id && $0.ingredientID == ingredient.id }
            if let selection = selection(from: newValue) {
                selections.append(selection)
            }
        }
    }

    private func selectionKey(groupID: UUID, ingredientID: UUID, portionID: UUID) -> String {
        "\(groupID.uuidString)|\(ingredientID.uuidString)|\(portionID.uuidString)"
    }

    private func selection(from key: String) -> CalculatorSelection? {
        let parts = key.split(separator: "|").map(String.init)
        guard parts.count == 3,
              let groupID = UUID(uuidString: parts[0]),
              let ingredientID = UUID(uuidString: parts[1]),
              let portionID = UUID(uuidString: parts[2]) else {
            return nil
        }
        return CalculatorSelection(groupID: groupID, ingredientID: ingredientID, portionID: portionID)
    }

    private func resolvedSelection(
        _ selection: CalculatorSelection
    ) -> (group: CalculatorGroup, ingredient: CalculatorIngredient, portion: CalculatorPortionOption)? {
        guard let group = calculator.calculatorGroups.first(where: { $0.id == selection.groupID }),
              let ingredient = group.ingredients.first(where: { $0.id == selection.ingredientID }),
              let portion = ingredient.portions.first(where: { $0.id == selection.portionID }) else {
            return nil
        }

        return (group, ingredient, portion)
    }

    private func quantityBinding(for selection: Binding<CalculatorSelection>) -> Binding<Double> {
        Binding {
            selection.wrappedValue.quantity
        } set: { value in
            selection.wrappedValue.quantity = max(value, 0.25)
        }
    }

    private func applyPreset(_ preset: CalculatorPreset) {
        let missing = SavedFood.missingCalculatorSelectionCount(
            for: calculator.calculatorGroups,
            selections: preset.selections
        )
        if missing > 0 {
            presetWarning = "\(missing) saved selection\(missing == 1 ? "" : "s") no longer exist in this calculator. Review the build before logging."
        }
        selections = preset.selections.filter {
            SavedFood.missingCalculatorSelectionCount(for: calculator.calculatorGroups, selections: [$0]) == 0
        }
        if let index = calculator.calculatorPresets.firstIndex(where: { $0.id == preset.id }) {
            calculator.calculatorPresets[index].lastUsedAt = .now
            try? modelContext.save()
            tursoMirror.scheduleMirror(reason: "nutrition_calculator_preset_used")
        }
    }

    private func savePreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selections.isEmpty else { return }
        calculator.calculatorPresets.append(CalculatorPreset(name: trimmed, selections: selections))
        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "nutrition_calculator_preset_saved")
    }

    private func logBuild() {
        let trimmedName = buildName.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = SavedFood.calculatorSelectionSummary(
            for: calculator.calculatorGroups,
            selections: selections
        )
        let entry = NutritionEntry(
            name: trimmedName,
            mealType: mealType,
            scanMode: .manual,
            calories: totals.calories,
            protein: totals.protein,
            carbs: totals.carbs,
            fat: totals.fat,
            micronutrients: totals.micronutrients,
            servingSize: "1 calculator build",
            brand: calculator.brand ?? calculator.name,
            servingQuantity: 1,
            servingUnit: "build",
            savedFoodID: calculator.id
        )
        entry.selectionSummary = summary.nilIfEmpty

        nutritionStore.log(entry, to: logDate)
        calculator.markLoggedForFoodBank()
        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "nutrition_calculator_logged")
        syncToHealthKitIfNeeded(entry)
        dismiss()
    }

    private func syncToHealthKitIfNeeded(_ entry: NutritionEntry) {
        guard healthKitEnabled else { return }
        Task {
            await healthKit.sync(entry, in: modelContext)
        }
    }
}

private struct CalculatorGroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let group: CalculatorGroup
    let onSave: (CalculatorGroup) -> Void

    @State private var name: String
    @State private var isRequired: Bool
    @State private var selectionRule: CalculatorSelectionRule
    @State private var ingredients: [CalculatorIngredient]
    @State private var editingIngredient: CalculatorIngredient?

    init(group: CalculatorGroup, onSave: @escaping (CalculatorGroup) -> Void) {
        self.group = group
        self.onSave = onSave
        _name = State(initialValue: group.name)
        _isRequired = State(initialValue: group.isRequired)
        _selectionRule = State(initialValue: group.selectionRule)
        _ingredients = State(initialValue: group.ingredients)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    TextField("Group name", text: $name)
                    Picker("Selection", selection: $selectionRule) {
                        ForEach(CalculatorSelectionRule.allCases) { rule in
                            Text(rule.label).tag(rule)
                        }
                    }
                    Toggle("Required", isOn: $isRequired)
                }

                Section("Ingredients") {
                    if ingredients.isEmpty {
                        Text("Add ingredients, then define runtime portion labels for each one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ingredients) { ingredient in
                            Button {
                                editingIngredient = ingredient
                            } label: {
                                CalculatorIngredientRow(ingredient: ingredient)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            ingredients.remove(atOffsets: offsets)
                        }
                    }

                    Button {
                        let ingredient = CalculatorIngredient(name: "")
                        editingIngredient = ingredient
                    } label: {
                        Label("Add Ingredient", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(CalculatorGroup(
                            id: group.id,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            isRequired: isRequired,
                            selectionRule: selectionRule,
                            ingredients: ingredients
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(item: $editingIngredient) { ingredient in
                CalculatorIngredientEditorSheet(ingredient: ingredient) { updated in
                    if let index = ingredients.firstIndex(where: { $0.id == updated.id }) {
                        ingredients[index] = updated
                    } else {
                        ingredients.append(updated)
                    }
                }
            }
        }
    }
}

private struct CalculatorIngredientEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let ingredient: CalculatorIngredient
    let onSave: (CalculatorIngredient) -> Void

    @State private var name: String
    @State private var note: String
    @State private var portions: [CalculatorPortionOption]
    @State private var editingPortion: CalculatorPortionOption?

    init(ingredient: CalculatorIngredient, onSave: @escaping (CalculatorIngredient) -> Void) {
        self.ingredient = ingredient
        self.onSave = onSave
        _name = State(initialValue: ingredient.name)
        _note = State(initialValue: ingredient.note ?? "")
        _portions = State(initialValue: ingredient.portions)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ingredient") {
                    TextField("Ingredient name", text: $name)
                    TextField("Note (optional)", text: $note)
                }

                Section("Runtime Portions") {
                    if portions.isEmpty {
                        Text("Portion labels are typed by the user from the restaurant or brand data, not hard-coded by the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(portions) { portion in
                            Button {
                                editingPortion = portion
                            } label: {
                                CalculatorPortionRow(portion: portion)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            portions.remove(atOffsets: offsets)
                        }
                    }

                    Button {
                        let portion = CalculatorPortionOption(label: "", calories: 0, protein: 0, carbs: 0, fat: 0)
                        editingPortion = portion
                    } label: {
                        Label("Add Portion", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(CalculatorIngredient(
                            id: ingredient.id,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                            portions: portions
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(item: $editingPortion) { portion in
                CalculatorPortionEditorSheet(portion: portion) { updated in
                    if let index = portions.firstIndex(where: { $0.id == updated.id }) {
                        portions[index] = updated
                    } else {
                        portions.append(updated)
                    }
                }
            }
        }
    }
}

private struct CalculatorPortionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let portion: CalculatorPortionOption
    let onSave: (CalculatorPortionOption) -> Void

    @State private var label: String
    @State private var caloriesText: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String
    @State private var micronutrients: [CalculatorMicroDraft]

    init(portion: CalculatorPortionOption, onSave: @escaping (CalculatorPortionOption) -> Void) {
        self.portion = portion
        self.onSave = onSave
        _label = State(initialValue: portion.label)
        _caloriesText = State(initialValue: CalculatorFormat.number(portion.calories))
        _proteinText = State(initialValue: CalculatorFormat.number(portion.protein))
        _carbsText = State(initialValue: CalculatorFormat.number(portion.carbs))
        _fatText = State(initialValue: CalculatorFormat.number(portion.fat))
        _micronutrients = State(initialValue: portion.micronutrients.keys.sorted().compactMap { name in
            guard let value = portion.micronutrients[name] else { return nil }
            return CalculatorMicroDraft(name: name, valueText: CalculatorFormat.number(value.value), unit: value.unit)
        })
    }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        Double(caloriesText) != nil &&
        Double(proteinText) != nil &&
        Double(carbsText) != nil &&
        Double(fatText) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Portion") {
                    TextField("Runtime label", text: $label)
                    macroField("Calories", text: $caloriesText, unit: "cal")
                    macroField("Protein", text: $proteinText, unit: "g")
                    macroField("Carbs", text: $carbsText, unit: "g")
                    macroField("Fat", text: $fatText, unit: "g")
                }

                Section("Micronutrients") {
                    ForEach($micronutrients) { $micro in
                        HStack {
                            TextField("Name", text: $micro.name)
                            TextField("Value", text: $micro.valueText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            TextField("Unit", text: $micro.unit)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52)
                        }
                    }
                    .onDelete { offsets in
                        micronutrients.remove(atOffsets: offsets)
                    }

                    Button {
                        micronutrients.append(CalculatorMicroDraft(name: "", valueText: "", unit: "mg"))
                    } label: {
                        Label("Add Nutrient", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Portion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(editedPortion)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
    }

    private var editedPortion: CalculatorPortionOption {
        var micros: [String: MicronutrientValue] = [:]
        for micro in micronutrients {
            let name = micro.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = micro.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !unit.isEmpty, let value = Double(micro.valueText) else { continue }
            micros[name] = MicronutrientValue(value: value, unit: unit)
        }

        return CalculatorPortionOption(
            id: portion.id,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            calories: Double(caloriesText) ?? 0,
            protein: Double(proteinText) ?? 0,
            carbs: Double(carbsText) ?? 0,
            fat: Double(fatText) ?? 0,
            micronutrients: micros
        )
    }

    private func macroField(_ title: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }
}

private struct CalculatorGroupRow: View {
    let group: CalculatorGroup

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .fontWeight(.medium)
                Text("\(group.selectionRule.label) · \(group.ingredients.count) ingredient\(group.ingredients.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct CalculatorIngredientRow: View {
    let ingredient: CalculatorIngredient

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(ingredient.name)
                    .fontWeight(.medium)
                Text("\(ingredient.portions.count) runtime portion\(ingredient.portions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct CalculatorPortionRow: View {
    let portion: CalculatorPortionOption

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(portion.label)
                    .fontWeight(.medium)
                Text("\(CalculatorFormat.number(portion.calories)) cal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                MacroChip(value: portion.protein, color: .blue, label: "P")
                MacroChip(value: portion.carbs, color: .green, label: "C")
                MacroChip(value: portion.fat, color: .yellow, label: "F")
            }
        }
    }
}

private struct CalculatorOCRRowView: View {
    let row: CalculatorOCRRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.ingredientName)
                .fontWeight(.medium)
            Text("\((row.groupName ?? "Imported")) · \(row.portionLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("\(CalculatorFormat.number(row.calories)) cal")
                MacroChip(value: row.protein, color: .blue, label: "P")
                MacroChip(value: row.carbs, color: .green, label: "C")
                MacroChip(value: row.fat, color: .yellow, label: "F")
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

private struct CalculatorMacroCard: View {
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
                Text(CalculatorFormat.number(value))
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.semibold)
                    .monospacedDigit()
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

private struct CalculatorMicroDraft: Identifiable {
    let id = UUID()
    var name: String
    var valueText: String
    var unit: String
}

private enum CalculatorFormat {
    static func number(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    NutritionCalculatorLibraryView(logDate: .now)
        .modelContainer(ModelContainer.preview)
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(HealthKitService())
        .environment(ScanService())
}
