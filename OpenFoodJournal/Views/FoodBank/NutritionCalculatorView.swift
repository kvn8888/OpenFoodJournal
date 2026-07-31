// OpenFoodJournal — NutritionCalculatorView
// Runtime-configurable restaurant/brand nutrition calculators.
// AGPL-3.0 License

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

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
                 ? "Add a restaurant or brand calculator, then build custom meals from portion options."
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
    @Environment(TursoMirrorService.self) private var tursoMirror

    private let calculator: SavedFood?
    /// Invoked after a successful save with the created/updated calculator.
    /// Used by the Assistant's review flow to report the outcome back to the AI.
    private let onSaved: ((SavedFood) -> Void)?

    @State private var name: String
    @State private var brand: String
    @State private var ingredients: [CalculatorIngredient]
    @State private var editingIngredient: CalculatorIngredient?
    @State private var showDeleteConfirm = false

    /// Prefill parameters let the Assistant open this editor with an
    /// AI-drafted calculator (or AI-proposed changes to an existing one)
    /// for user review before anything is persisted.
    init(
        calculator: SavedFood? = nil,
        prefillName: String? = nil,
        prefillBrand: String? = nil,
        prefillIngredients: [CalculatorIngredient]? = nil,
        onSaved: ((SavedFood) -> Void)? = nil
    ) {
        self.calculator = calculator
        self.onSaved = onSaved
        _name = State(initialValue: prefillName ?? calculator?.name ?? "")
        _brand = State(initialValue: prefillBrand ?? calculator?.brand ?? "")
        _ingredients = State(initialValue: prefillIngredients ?? calculator?.calculatorIngredients ?? [])
    }

    private var isEditing: Bool { calculator != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                ingredientsSection
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
            .sheet(item: $editingIngredient) { ingredient in
                CalculatorIngredientEditorSheet(ingredient: ingredient) { updated in
                    if let index = ingredients.firstIndex(where: { $0.id == updated.id }) {
                        ingredients[index] = updated
                    } else {
                        ingredients.append(updated)
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
            TextField("Brand note (optional)", text: $brand)
        }
    }

    private var ingredientsSection: some View {
        Section {
            if ingredients.isEmpty {
                Text("Add ingredients like rice, protein, salsa, toppings, or any brand-specific component.")
                    .font(.subheadline)
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
                editingIngredient = CalculatorIngredient(name: "")
            } label: {
                Label("Add Ingredient", systemImage: "plus.circle")
            }
        } header: {
            Text("Ingredients")
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

    private func saveCalculator() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)

        let saved: SavedFood
        if let calculator {
            calculator.name = trimmedName
            calculator.brand = trimmedBrand.nilIfEmpty
            calculator.kind = .calculator
            calculator.calculatorIngredients = ingredients
            calculator.refreshCalculatorNutrition()
            saved = calculator
        } else {
            let calculator = SavedFood(
                name: trimmedName,
                brand: trimmedBrand.nilIfEmpty,
                calories: 0,
                protein: 0,
                carbs: 0,
                fat: 0,
                servingSize: ingredientCountText(ingredients.count),
                servingQuantity: 1,
                servingUnit: "meal",
                kind: .calculator,
                calculatorIngredients: ingredients
            )
            calculator.refreshCalculatorNutrition()
            modelContext.insert(calculator)
            saved = calculator
        }

        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: isEditing ? "nutrition_calculator_updated" : "nutrition_calculator_created")
        onSaved?(saved)
        dismiss()
    }
}

struct NutritionCalculatorBuildView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(TursoMirrorService.self) private var tursoMirror
    @Environment(MealTimeSettings.self) private var mealTimeSettings

    @Bindable var calculator: SavedFood
    let logDate: Date

    @State private var mealType: MealType = .snack
    @State private var mealTypeWasEdited = false
    @State private var didApplyDefaultMealType = false
    @State private var buildName: String
    @State private var selections: [CalculatorSelection] = []

    init(calculator: SavedFood, logDate: Date) {
        self.calculator = calculator
        self.logDate = logDate
        _buildName = State(initialValue: calculator.name)
    }

    private var totals: CompositeNutritionTotals {
        SavedFood.calculatorTotals(for: calculator.calculatorIngredients, selections: selections)
    }

    private var canLog: Bool {
        !selections.isEmpty &&
        !buildName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                ingredientsSection
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
            .onAppear {
                applyDefaultMealTypeIfNeeded()
            }
        }
    }

    private var summarySection: some View {
        Section("Build") {
            TextField("Logged meal name", text: $buildName)

            Picker("Meal", selection: mealTypeBinding) {
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

    private var ingredientsSection: some View {
        Section("Ingredients") {
            if calculator.calculatorIngredients.isEmpty {
                Text("This calculator has no ingredients yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(calculator.calculatorIngredients) { ingredient in
                    if ingredient.portions.isEmpty {
                        Text(ingredient.name)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(ingredient.name, selection: portionBinding(for: ingredient)) {
                            Text("None").tag("")
                            ForEach(ingredient.portions) { portion in
                                Text(portion.label)
                                    .tag(selectionKey(ingredientID: ingredient.id, portionID: portion.id))
                            }
                        }
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
                                    Text(resolved.portion.label)
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
                                        .ofjNumericTextTransition(
                                            value: selection.quantity
                                        )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } header: {
                Text("Quantities")
            } footer: {
                Text("Adjust quantities for double portions or multiple scoops without changing saved nutrition values.")
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
        } footer: {
            if selections.isEmpty {
                Text("Choose at least one ingredient to log this meal.")
            }
        }
    }

    private func portionBinding(for ingredient: CalculatorIngredient) -> Binding<String> {
        Binding {
            guard let selection = selections.first(where: { $0.ingredientID == ingredient.id }) else { return "" }
            return selectionKey(ingredientID: selection.ingredientID, portionID: selection.portionID)
        } set: { newValue in
            selections.removeAll { $0.ingredientID == ingredient.id }
            if let selection = selection(from: newValue) {
                selections.append(selection)
            }
        }
    }

    private func selectionKey(ingredientID: UUID, portionID: UUID) -> String {
        "\(ingredientID.uuidString)|\(portionID.uuidString)"
    }

    private func selection(from key: String) -> CalculatorSelection? {
        let parts = key.split(separator: "|").map(String.init)
        guard parts.count == 2,
              let ingredientID = UUID(uuidString: parts[0]),
              let portionID = UUID(uuidString: parts[1]) else {
            return nil
        }
        return CalculatorSelection(ingredientID: ingredientID, portionID: portionID)
    }

    private func resolvedSelection(
        _ selection: CalculatorSelection
    ) -> (ingredient: CalculatorIngredient, portion: CalculatorPortionOption)? {
        guard let ingredient = calculator.calculatorIngredients.first(where: { $0.id == selection.ingredientID }),
              let portion = ingredient.portions.first(where: { $0.id == selection.portionID }) else {
            return nil
        }

        return (ingredient, portion)
    }

    private func quantityBinding(for selection: Binding<CalculatorSelection>) -> Binding<Double> {
        Binding {
            selection.wrappedValue.quantity
        } set: { value in
            selection.wrappedValue.quantity = max(value, 0.25)
        }
    }

    private func logBuild() {
        let trimmedName = buildName.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = SavedFood.calculatorSelectionSummary(
            for: calculator.calculatorIngredients,
            selections: selections
        )
        let entry = NutritionEntry(
            name: trimmedName,
            mealType: mealTypeForLog,
            scanMode: .manual,
            calories: totals.calories,
            protein: totals.protein,
            carbs: totals.carbs,
            fat: totals.fat,
            micronutrients: totals.micronutrients,
            servingSize: "1 meal",
            brand: calculator.brand ?? calculator.name,
            servingQuantity: 1,
            servingUnit: "meal",
            savedFoodID: calculator.id
        )
        entry.selectionSummary = summary.nilIfEmpty

        nutritionStore.log(entry, to: logDate)
        calculator.markLoggedForFoodBank()
        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "nutrition_calculator_logged")
        dismiss()
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

}

private struct CalculatorIngredientEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScanService.self) private var scanService
    @AppStorage("scan.useProModel") private var useProModel: Bool = false

    let ingredient: CalculatorIngredient
    let onSave: (CalculatorIngredient) -> Void

    @State private var name: String
    @State private var note: String
    @State private var portions: [CalculatorPortionOption]
    @State private var editingPortion: CalculatorPortionOption?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var capturedImages: [UIImage] = []
    @State private var showPhotoLibrary = false
    @State private var showImageSourceDialog = false
    @State private var showCameraCapture = false
    @State private var ocrError: String?
    @State private var isImportingOCR = false

    init(ingredient: CalculatorIngredient, onSave: @escaping (CalculatorIngredient) -> Void) {
        self.ingredient = ingredient
        self.onSave = onSave
        _name = State(initialValue: ingredient.name)
        _note = State(initialValue: ingredient.note ?? "")
        var labels: Set<String> = []
        _portions = State(initialValue: ingredient.portions.map { portion in
            var normalized = portion
            normalized.label = Self.uniquePortionLabel(preferred: portion.label, existingLabels: &labels)
            return normalized
        })
    }

    fileprivate static let defaultPortionLabel = "normal"

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasIngredientName: Bool {
        !trimmedName.isEmpty
    }

    private var canSave: Bool {
        hasIngredientName &&
        !hasUnnamedPortions
    }

    private var canImport: Bool {
        hasIngredientName && pendingImageCount > 0 && !isImportingOCR
    }

    private var importButtonLooksActive: Bool {
        canImport || isImportingOCR
    }

    private var hasUnnamedPortions: Bool {
        portions.contains {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var pendingImageCount: Int {
        selectedPhotoItems.count + capturedImages.count
    }

    private var remainingImageSlots: Int {
        max(ScanService.maxImagesPerScan - pendingImageCount, 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ingredient") {
                    TextField("Ingredient name", text: $name)
                    TextField("Note (optional)", text: $note)
                }

                nutritionImportSection
                quickActionsSection
                portionsSection
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
                            name: trimmedName,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                            portions: portions
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .sheet(item: $editingPortion) { portion in
                CalculatorPortionEditorSheet(portion: portion) { updated in
                    upsertPortion(updated)
                }
            }
            .sheet(isPresented: $showCameraCapture) {
                CalculatorCameraCaptureView { image in
                    guard pendingImageCount < ScanService.maxImagesPerScan else { return }
                    capturedImages.append(image)
                }
            }
            .photosPicker(
                isPresented: $showPhotoLibrary,
                selection: $selectedPhotoItems,
                maxSelectionCount: max(remainingImageSlots, 1),
                matching: .images
            )
            .confirmationDialog(
                "Choose Image",
                isPresented: $showImageSourceDialog,
                titleVisibility: .visible
            ) {
                Button {
                    showPhotoLibrary = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showCameraCapture = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                }

                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var nutritionImportSection: some View {
        Section {
            Button {
                showImageSourceDialog = true
            } label: {
                Label("Choose Image", systemImage: "photo")
            }
            .disabled(remainingImageSlots == 0)

            if pendingImageCount > 0 {
                HStack {
                    Label("\(pendingImageCount) image\(pendingImageCount == 1 ? "" : "s") ready", systemImage: "photo.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        selectedPhotoItems = []
                        capturedImages = []
                    }
                    .font(.caption)
                }
            }

            Button {
                Task { await importFromImage() }
            } label: {
                Group {
                    if isImportingOCR {
                        HStack {
                            ProgressView()
                            Text("Filling Nutrients")
                        }
                    } else {
                        Label("Import from Image", systemImage: "wand.and.sparkles")
                    }
                }
                .foregroundStyle(importButtonLooksActive ? Color.accentColor : Color.secondary)
                .opacity(importButtonLooksActive ? 1 : 0.5)
            }
            .disabled(!canImport)

            if let ocrError {
                Text(ocrError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Import Nutrition")
        } footer: {
            Text("Type the ingredient name first, then import nutrition from an image or add portions manually.")
        }
    }

    @ViewBuilder
    private var quickActionsSection: some View {
        if let base = portions.first {
            Section("Quick Portions") {
                Button {
                    upsertPortion(base.scaledPortion(by: 0.5, label: "Light"))
                } label: {
                    Label("Add Light (1/2x)", systemImage: "minus.circle")
                }

                Button {
                    upsertPortion(base.scaledPortion(by: 2.0, label: "Extra"))
                } label: {
                    Label("Add Extra (2x)", systemImage: "plus.circle")
                }

                Button {
                    editingPortion = newBlankPortion()
                } label: {
                    Label("Add Custom...", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private var portionsSection: some View {
        Section("Portions") {
            if portions.isEmpty {
                Text("Choose an image showing this ingredient's nutrition info. Portions will be filled in automatically.")
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

            if hasUnnamedPortions {
                Label("Name each imported portion before saving.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                editingPortion = newBlankPortion()
            } label: {
                Label("Add Portion", systemImage: "plus.circle")
            }
        }
    }

    private func importFromImage() async {
        isImportingOCR = true
        ocrError = nil
        defer { isImportingOCR = false }

        var images: [UIImage] = []
        for item in selectedPhotoItems {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            images.append(image)
        }
        images.append(contentsOf: capturedImages)

        do {
            let draft = try await scanService.extractCalculatorIngredient(
                named: trimmedName,
                from: images,
                useProModel: useProModel
            )
            var labels = Set(portions.map { normalizedPortionLabel($0.label) })
            let imported = draft.portions.map {
                CalculatorPortionOption(
                    label: Self.uniquePortionLabel(preferred: $0.label, existingLabels: &labels),
                    calories: $0.calories,
                    protein: $0.protein,
                    carbs: $0.carbs,
                    fat: $0.fat,
                    micronutrients: $0.micronutrients
                )
            }

            if imported.isEmpty {
                ocrError = "No usable portions were found. Try a clearer image."
            } else {
                portions.append(contentsOf: imported)
                selectedPhotoItems = []
                capturedImages = []
                editingPortion = imported.first
            }
        } catch {
            ocrError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func upsertPortion(_ portion: CalculatorPortionOption) {
        let label = portion.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            editingPortion = portion
            return
        }

        var normalized = portion
        normalized.label = label
        if let index = portions.firstIndex(where: { $0.id == normalized.id }) {
            portions[index] = normalized
        } else if let index = portions.firstIndex(where: {
            $0.label.caseInsensitiveCompare(label) == .orderedSame
        }) {
            portions[index] = normalized
        } else {
            portions.append(normalized)
        }
    }

    private func newBlankPortion() -> CalculatorPortionOption {
        CalculatorPortionOption(
            label: newPortionLabel(),
            calories: 0,
            protein: 0,
            carbs: 0,
            fat: 0
        )
    }

    private func newPortionLabel(preferred: String? = nil) -> String {
        var labels = Set(portions.map { normalizedPortionLabel($0.label) })
        return Self.uniquePortionLabel(preferred: preferred, existingLabels: &labels)
    }

    private static func uniquePortionLabel(preferred: String? = nil, existingLabels: inout Set<String>) -> String {
        let trimmed = preferred?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? Self.defaultPortionLabel : trimmed
        var candidate = base
        var suffix = 2

        while existingLabels.contains(normalizedPortionLabel(candidate)) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }

        existingLabels.insert(normalizedPortionLabel(candidate))
        return candidate
    }

    private static func normalizedPortionLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedPortionLabel(_ label: String) -> String {
        Self.normalizedPortionLabel(label)
    }
}

private struct CalculatorCameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CalculatorCameraCaptureView

        init(parent: CalculatorCameraCaptureView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
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
        let initialLabel = portion.label.trimmingCharacters(in: .whitespacesAndNewlines)
        _label = State(initialValue: initialLabel.isEmpty ? CalculatorIngredientEditorSheet.defaultPortionLabel : initialLabel)
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
        !trimmedLabel.isEmpty &&
        Double(caloriesText) != nil &&
        Double(proteinText) != nil &&
        Double(carbsText) != nil &&
        Double(fatText) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Portion") {
                    TextField("Portion name", text: $label)
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
            label: trimmedLabel.isEmpty ? CalculatorIngredientEditorSheet.defaultPortionLabel : trimmedLabel,
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

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CalculatorIngredientRow: View {
    let ingredient: CalculatorIngredient

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(ingredient.name)
                    .fontWeight(.medium)
                Text("\(ingredient.portions.count) portion\(ingredient.portions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .ofjNumericTextTransition(value: ingredient.portions.count)
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
        let label = portion.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = label.isEmpty ? CalculatorIngredientEditorSheet.defaultPortionLabel : label
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayLabel)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.primary)
                Text("\(CalculatorFormat.number(portion.calories)) cal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .ofjNumericTextTransition(value: portion.calories)
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

private struct CalculatorMicroDraft: Identifiable {
    let id = UUID()
    var name: String
    var valueText: String
    var unit: String
}

private func ingredientCountText(_ count: Int) -> String {
    "\(count) ingredient\(count == 1 ? "" : "s")"
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
        .environment(MealTimeSettings())
}
