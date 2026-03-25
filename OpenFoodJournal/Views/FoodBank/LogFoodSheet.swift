// OpenFoodJournal — LogFoodSheet
// Presented when the user taps a saved food in the Food Bank.
// Shows the food's nutrition details and lets the user pick a meal type,
// then logs it to today's journal with one tap.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct LogFoodSheet: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    // ── Input: the saved food to potentially log ──────────────────
    let food: SavedFood
    /// The date to log this food to (passed from DailyLogView's selected date)
    let logDate: Date

    // ── Local State ───────────────────────────────────────────────
    // The meal type the user selects before logging (defaults to snack)
    @State private var selectedMealType: MealType = .snack
    // Quantity of this food the user wants to log (in the selected unit)
    @State private var quantity: Double
    // Text backing for the quantity field — avoids cursor-jump with direct Double binding
    @State private var quantityText: String
    // The unit the user has selected for this log (may differ from the food's stored unit)
    @State private var selectedUnit: String
    // Controls the nested Edit Food sheet
    @State private var showEditFood = false
    // Controls the Add Serving Mapping sheet
    @State private var showAddMapping = false

    // Centralised unit conversion + macro scaling logic (shared with EditEntryView)
    private let converter: ServingConverter

    // Keep baseUnit accessible for onChange unit-switch logic
    private let baseUnit: String

    init(food: SavedFood, logDate: Date = .now) {
        self.food = food
        self.logDate = logDate
        let qty = food.servingQuantity ?? 1.0
        let unit = food.servingUnit ?? "serving"
        _quantity = State(initialValue: qty)
        _quantityText = State(initialValue: qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", qty) : String(format: "%.2f", qty))
        _selectedUnit = State(initialValue: unit)
        self.baseUnit = unit
        self.converter = ServingConverter(
            calories: food.calories,
            protein: food.protein,
            carbs: food.carbs,
            fat: food.fat,
            quantity: qty,
            unit: unit,
            serving: food.serving,
            mappings: food.servingMappings
        )
    }

    // MARK: - Serving computed helpers (delegated to ServingConverter)

    private var availableUnits: [String] { converter.availableUnits }
    private var unitFactor: Double { converter.factorFor(selectedUnit) }
    private var scaledCalories: Double { converter.scaledCalories(quantity: quantity, unit: selectedUnit) }
    private var scaledProtein: Double { converter.scaledProtein(quantity: quantity, unit: selectedUnit) }
    private var scaledCarbs: Double { converter.scaledCarbs(quantity: quantity, unit: selectedUnit) }
    private var scaledFat: Double { converter.scaledFat(quantity: quantity, unit: selectedUnit) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // ── Food identity section ─────────────────────────
                    headerSection

                    Divider()

                    // ── Core macros grid ──────────────────────────────
                    macroGrid

                    // ── Micronutrients (if any) ──────────────────────
                    if !food.micronutrients.isEmpty {
                        micronutrientSection
                    }

                    Divider()

                    // ── Serving quantity adjustment ────────────────────
                    servingSection

                    Divider()

                    // ── Custom unit mappings ──────────────────────────
                    // Lets the user define conversions like "1 cup = 244g" so
                    // those units appear in the unit picker above.
                    servingMappingsSection

                    Divider()

                    // ── Meal type picker ──────────────────────────────
                    mealPicker

                    // ── Log button ────────────────────────────────────
                    logButton
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Log Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Edit Food — opens EditFoodSheet as a nested sheet so the user can
                // correct macros, name, or brand without leaving the log flow
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showEditFood = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                }
                // "Done" dismisses the decimal pad keyboard
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                }
            }
            // Nested sheet for editing the food's name, brand, and macros
            .sheet(isPresented: $showEditFood) {
                EditFoodSheet(food: food)
            }
            // Nested sheet for defining a new unit conversion mapping
            .sheet(isPresented: $showAddMapping) {
                AddServingMappingSheet { mapping in
                    addMapping(mapping)
                }
            }
        }
    }

    // MARK: - Header

    /// Shows the food name, serving size, and how it was originally captured
    private var headerSection: some View {
        VStack(spacing: 8) {
            // Source badge (label scan, food photo, or manual)
            HStack {
                Image(systemName: sourceIcon)
                Text(sourceLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: .capsule)

            // Brand (if available)
            if let brand = food.brand, !brand.isEmpty {
                Text(brand)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Food name
            Text(food.name)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            // Serving size if available
            if let serving = food.servingSize {
                Text(serving)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Macro Grid

    /// Single row of macro rings showing value vs. daily goal
    private var macroGrid: some View {
        HStack(spacing: 0) {
            MacroRingView(value: scaledCalories, goal: goals.dailyCalories, color: .orange, label: "Calories", unit: "kcal")
                .frame(maxWidth: .infinity)
            MacroRingView(value: scaledProtein, goal: goals.dailyProtein, color: .blue, label: "Protein", unit: "g")
                .frame(maxWidth: .infinity)
            MacroRingView(value: scaledCarbs, goal: goals.dailyCarbs, color: .green, label: "Carbs", unit: "g")
                .frame(maxWidth: .infinity)
            MacroRingView(value: scaledFat, goal: goals.dailyFat, color: .yellow, label: "Fat", unit: "g")
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Micronutrients

    /// Expandable section showing all dynamic micronutrients with progress bars
    private var micronutrientSection: some View {
        DisclosureGroup {
            VStack(spacing: 10) {
                let sorted = food.micronutrients.keys.sorted()
                ForEach(sorted, id: \.self) { name in
                    if let micro = food.micronutrients[name] {
                        let scaledValue = micro.value * quantity / unitFactor / converter.baseQuantity
                        let known = KnownMicronutrients.find(name)
                        MicronutrientProgressRow(
                            name: known?.name ?? name,
                            value: scaledValue,
                            unit: micro.unit,
                            dailyValue: known?.dailyValue
                        )
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Micronutrients (\(food.micronutrients.count))", systemImage: "list.bullet")
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }

    // MARK: - Meal Picker

    /// Segmented picker for choosing which meal to log the food under
    private var mealPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log as")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Picker("Meal Type", selection: $selectedMealType) {
                ForEach(MealType.allCases) { meal in
                    Text(meal.rawValue.capitalized).tag(meal)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Log Button

    /// The primary action button: creates a NutritionEntry from the saved food
    /// and adds it to today's log via NutritionStore.
    /// Macros are scaled proportionally by the quantity/unit the user selected.
    private var logButton: some View {
        Button {
            // Create the entry from the food template
            var entry = food.toNutritionEntry(mealType: selectedMealType)
            // Scale all macros by the ratio of (selected quantity / base serving size)
            let factor = quantity / unitFactor / converter.baseQuantity
            entry.calories *= factor
            entry.protein *= factor
            entry.carbs *= factor
            entry.fat *= factor
            // Scale micronutrients by the same factor
            for (key, micro) in entry.micronutrients {
                entry.micronutrients[key] = MicronutrientValue(
                    value: micro.value * factor,
                    unit: micro.unit
                )
            }
            // Store what the user actually typed so EditEntryView can use it as
            // the correct baseline.  Without this, opening the edit sheet shows the
            // food's template quantity/unit (e.g. "1 serving") even though the macros
            // were scaled for a different amount (e.g. "250 g").
            entry.servingQuantity = quantity
            entry.servingUnit = selectedUnit
            // Update lastUsedAt so this food surfaces to the top of "Last Used" sort
            food.lastUsedAt = .now
            nutritionStore.log(entry, to: logDate)
            dismiss()
        } label: {
            Text("Add to Journal")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - Serving Section

    /// Lets the user type a quantity and select a unit.
    /// The macro grid above live-updates as quantity and unit change.
    /// Mirrors the serving editor in EditEntryView.
    private var servingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quantity")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                // Quantity input — decimal keyboard, live-updates macros
                TextField("Amount", text: $quantityText)
                    .keyboardType(.decimalPad)
                    .font(.title2.monospacedDigit())
                    .fontWeight(.bold)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                    .onChange(of: quantityText) { _, newValue in
                        // Accept only valid positive numbers; ignore empty or non-numeric input
                        if let v = Double(newValue), v > 0 {
                            quantity = v
                        }
                    }

                // Unit picker — options come from the ServingSize enum or legacy mappings
                if availableUnits.count > 1 {
                    Picker("Unit", selection: $selectedUnit) {
                        ForEach(availableUnits, id: \.self) { unit in
                            Text(unit).tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.title2)
                    .fontWeight(.semibold)
                    // Auto-convert quantity when the user switches units
                    // e.g. "1 cup" → "240 g" so the macros stay equivalent
                    .onChange(of: selectedUnit) { oldUnit, newUnit in
                        let oldFactor = converter.factorFor(oldUnit)
                        let newFactor = converter.factorFor(newUnit)
                        guard oldFactor > 0, newFactor > 0 else { return }
                        let converted = quantity * newFactor / oldFactor
                        quantity = converted
                        quantityText = converted.truncatingRemainder(dividingBy: 1) == 0
                            ? String(format: "%.0f", converted)
                            : String(format: "%.2f", converted)
                    }
                } else {
                    // Only one unit available — show it as static text
                    Text(selectedUnit)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }

            // Helper caption: what the food's canonical serving is
            if let size = food.servingSize {
                Text("1 serving = \(size)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Serving Mappings

    /// Shows the food's custom unit conversion mappings and lets the user add new ones.
    /// New mappings (e.g. "1 cup = 244g") are saved to SwiftData and synced to Turso,
    /// and immediately appear in the unit picker above.
    private var servingMappingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Unit Mappings")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                // Opens the AddServingMappingSheet for a new from→to conversion
                Button {
                    showAddMapping = true
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(.subheadline)
                }
            }

            if food.servingMappings.isEmpty {
                // Hint text when no mappings exist yet
                Text("Define custom unit conversions for this food (e.g. 1 cup = 244g). These will appear as unit options in the picker above.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Show each existing mapping as a simple arrow expression
                ForEach(food.servingMappings, id: \.self) { mapping in
                    HStack(spacing: 6) {
                        Text(mapping.from.displayString)
                            .fontWeight(.medium)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(mapping.to.displayString)
                        Spacer()
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    /// Appends a new serving mapping to the food and saves to SwiftData.
    private func addMapping(_ mapping: ServingMapping) {
        food.servingMappings.append(mapping)
        try? modelContext.save()
    }

    // MARK: - Helpers

    /// SF Symbol for the food's original capture method
    private var sourceIcon: String {
        switch food.originalScanMode {
        case .label: "barcode.viewfinder"
        case .foodPhoto: "fork.knife"
        case .manual: "pencil.circle"
        }
    }

    /// Human-readable label for the food's origin
    private var sourceLabel: String {
        switch food.originalScanMode {
        case .label: "Label Scan"
        case .foodPhoto: "Food Photo"
        case .manual: "Manual Entry"
        }
    }
}



// MARK: - Add Serving Mapping Sheet

/// A compact form for defining a new unit conversion for a food.
/// For example: "1 cup → 244 g" means the user can later enter "1 cup"
/// in the quantity picker and the app will scale macros accordingly.
/// The caller receives the completed `ServingMapping` via the `onAdd` closure.
/// Internal (not private) so EditEntryView can reuse the same sheet.
struct AddServingMappingSheet: View {
    @Environment(\.dismiss) private var dismiss

    // Callback — parent (LogFoodSheet) handles the actual model mutation
    let onAdd: (ServingMapping) -> Void

    // ── From side ─────────────────────────────────────────────────
    @State private var fromValue: String = "1"
    @State private var fromUnit: String = "serving"

    // ── To side ───────────────────────────────────────────────────
    @State private var toValue: String = ""
    @State private var toUnit: String = "g"

    /// True when both sides have a valid positive number (enables Save button)
    private var isValid: Bool {
        guard let from = Double(fromValue), let to = Double(toValue),
              from > 0, to > 0,
              !fromUnit.trimmingCharacters(in: .whitespaces).isEmpty,
              !toUnit.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                // "From" side — user's input unit (e.g. 1 cup)
                Section {
                    HStack {
                        TextField("Amount", text: $fromValue)
                            .keyboardType(.decimalPad)
                            .frame(width: 80)
                        Divider()
                        TextField("Unit (e.g. cup, slice)", text: $fromUnit)
                    }
                } header: {
                    Text("From")
                } footer: {
                    Text("The unit you measure or describe the food in.")
                }

                // "To" side — equivalent in a standard unit (e.g. 244 g)
                Section {
                    HStack {
                        TextField("Amount", text: $toValue)
                            .keyboardType(.decimalPad)
                            .frame(width: 80)
                        Divider()
                        TextField("Unit (e.g. g, mL)", text: $toUnit)
                    }
                } header: {
                    Text("To")
                } footer: {
                    Text("The equivalent amount in a standard unit like grams or mL.")
                }

                // Preview — shows what the mapping will look like once saved
                if isValid {
                    Section("Preview") {
                        HStack(spacing: 6) {
                            Text("\(fromValue) \(fromUnit)")
                                .fontWeight(.medium)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            Text("\(toValue) \(toUnit)")
                        }
                        .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Add Unit Mapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Build and pass the mapping back to LogFoodSheet
                        let mapping = ServingMapping(
                            from: ServingAmount(value: Double(fromValue) ?? 1, unit: fromUnit.trimmingCharacters(in: .whitespaces)),
                            to: ServingAmount(value: Double(toValue) ?? 0, unit: toUnit.trimmingCharacters(in: .whitespaces))
                        )
                        onAdd(mapping)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
    }
}

// MARK: - Micronutrient Progress Row

/// A single micronutrient row with a progress bar showing % of daily value.
/// Shows "None" for the daily value when no FDA reference exists.
private struct MicronutrientProgressRow: View {
    let name: String
    let value: Double
    let unit: String
    let dailyValue: Double?  // nil = no known daily value

    private var progress: Double {
        guard let dv = dailyValue, dv > 0 else { return 0 }
        return min(value / dv, 1.0)
    }

    private var percentText: String {
        guard let dv = dailyValue, dv > 0 else { return "None" }
        return "\(Int((value / dv) * 100))%"
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(name)
                    .font(.subheadline)
                Spacer()
                Text("\(value, specifier: "%.1f") \(unit)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 6)
                        if dailyValue != nil && dailyValue! > 0 {
                            Capsule()
                                .fill(value > (dailyValue ?? 0) ? Color.orange : Color.accentColor)
                                .frame(width: geo.size.width * progress, height: 6)
                                .animation(.easeInOut, value: progress)
                        }
                    }
                }
                .frame(height: 6)

                Text(percentText)
                    .font(.caption2)
                    .foregroundStyle(dailyValue == nil ? .tertiary : .secondary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
