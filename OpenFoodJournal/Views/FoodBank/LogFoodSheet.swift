// OpenFoodJournal — LogFoodSheet
// Presented when the user taps a saved food in the Food Bank.
// Shows the food's nutrition details and lets the user pick a meal type,
// then logs it to today's journal with one tap.
// AGPL-3.0 License

import SwiftUI
import SwiftData
import UIKit

struct LogFoodSheet: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals
    @Environment(MealTimeSettings.self) private var mealTimeSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.ofjAccentTheme) private var accentTheme
    @AppStorage(FoodBankEmojiSettings.useGeneratedIconImagesKey) private var useGeneratedIconImages = false

    // ── Input: the saved food to potentially log ──────────────────
    let food: SavedFood
    /// The date to log this food to (passed from DailyLogView's selected date)
    let logDate: Date

    // ── Local State ───────────────────────────────────────────────
    // The meal type the user selects before logging (defaults from local time)
    @State private var selectedMealType: MealType = .snack
    @State private var mealTypeWasEdited = false
    @State private var didApplyDefaultMealType = false
    @State private var didApplyLastUsedServing = false
    // Quantity of this food the user wants to log (in the selected unit)
    @State private var quantity: Double
    // Text backing for the quantity field — avoids cursor-jump with direct Double binding
    @State private var quantityText: String
    @FocusState private var quantityIsFocused: Bool
    @State private var unitStripContentWidth: CGFloat = 0
    @State private var unitStripViewportWidth: CGFloat = 0
    // The unit the user has selected for this log (may differ from the food's stored unit)
    @State private var selectedUnit: String
    // Controls the nested Edit Food sheet
    @State private var showEditFood = false
    // Controls the Add/Edit Serving Mapping sheet
    @State private var showAddMapping = false
    // Index of mapping being edited (nil = adding new)
    @State private var editingMappingIndex: Int?
    // Editable micronutrient values — initialized from the food template, can be
    // adjusted by the user before logging. Scaling is applied at log time.
    @State private var editedMicros: [String: MicronutrientValue]

    // Centralised unit conversion + macro scaling logic (shared with EditEntryView)
    private let converter: ServingConverter

    init(
        food: SavedFood,
        logDate: Date = AppPresentationDate.now,
        initialQuantity: Double? = nil,
        initialUnit: String? = nil
    ) {
        self.food = food
        self.logDate = logDate
        let templateQuantity = food.servingQuantity ?? 1.0
        let templateUnit = food.servingUnit ?? "serving"
        let suggestedQuantity = initialQuantity.flatMap { $0 > 0 ? $0 : nil }
        let qty = suggestedQuantity ?? templateQuantity
        let unit = initialUnit?.isEmpty == false ? initialUnit! : templateUnit
        _quantity = State(initialValue: qty)
        _quantityText = State(initialValue: qty.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", qty) : String(format: "%.2f", qty))
        _selectedUnit = State(initialValue: unit)
        _didApplyLastUsedServing = State(initialValue: suggestedQuantity != nil && initialUnit?.isEmpty == false)
        _editedMicros = State(initialValue: food.micronutrients)
        self.converter = ServingConverter(
            calories: food.calories,
            protein: food.protein,
            carbs: food.carbs,
            fat: food.fat,
            quantity: templateQuantity,
            unit: templateUnit,
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
    private var micronutrientScaleFactor: Double {
        max((quantity / unitFactor) / converter.baseQuantity, 0.000_001)
    }
    private var scaledMicronutrients: [String: MicronutrientValue] {
        converter.scaledMicronutrients(
            editedMicros,
            quantity: quantity,
            unit: selectedUnit
        )
    }
    private var canvasColor: Color {
        OFJColor.logFoodCanvas(for: accentTheme, colorScheme: colorScheme)
    }
    private var cardColor: Color {
        OFJColor.logFoodCard(for: accentTheme, colorScheme: colorScheme)
    }
    private var currentDayCalories: Double {
        _ = nutritionStore.changeCount
        return nutritionStore.fetchLog(for: logDate)?.totalCalories ?? 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: OFJSpace.s16) {
                    headerSection
                    servingSection
                    nutritionSection

                    if !editedMicros.isEmpty {
                        micronutrientSection
                    }

                    if food.kind != .composite {
                        servingMappingsSection
                    }
                    mealPicker
                }
                .padding(.horizontal, OFJSpace.s16)
                .padding(.top, OFJSpace.s12)
                .padding(.bottom, OFJSpace.s24)
            }
            .background(canvasColor.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Log food")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                logButton
                    .padding(.horizontal, OFJSpace.s16)
                    .padding(.top, OFJSpace.s12)
                    .padding(.bottom, OFJSpace.s8)
                    .background(canvasColor.opacity(0.96))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showEditFood = true
                    } label: {
                        Text("Edit")
                    }
                }
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
                if food.kind == .calculator {
                    NutritionCalculatorEditorView(calculator: food)
                } else if food.kind == .composite {
                    CompositeFoodBuilderView(food: food)
                } else {
                    EditFoodSheet(food: food)
                }
            }
            // Nested sheet for defining a new or editing an existing unit conversion mapping
            .sheet(isPresented: $showAddMapping) {
                if let index = editingMappingIndex {
                    AddServingMappingSheet(existing: food.servingMappings[index]) { mapping in
                        updateMapping(at: index, with: mapping)
                    }
                } else {
                    AddServingMappingSheet { mapping in
                        addMapping(mapping)
                    }
                }
            }
            .onAppear {
                applyDefaultMealTypeIfNeeded()
                applyLastUsedServingIfNeeded()
            }
        }
        .tint(accentTheme.accentColor)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: OFJSpace.s12) {
            LogFoodHeaderIcon(
                food: food,
                useGeneratedIconImages: useGeneratedIconImages,
                surfaceColor: cardColor
            )

            VStack(alignment: .leading, spacing: OFJSpace.s3) {
                if let brand = food.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(food.name)
                    .font(.headline)
                    .lineLimit(2)

                Text(identitySubtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var identitySubtitle: String {
        var parts = [sourceLabel]
        if let servingDescription {
            parts.append(servingDescription)
        }
        return parts.joined(separator: " · ")
    }

    private var servingDescription: String? {
        guard let servingSize = food.servingSize, !servingSize.isEmpty else {
            return nil
        }
        let quantity = food.servingQuantity ?? 1
        let unit = food.servingUnit ?? "serving"
        return "\(formattedQuantity(quantity)) \(LogFoodPresentation.unitLabel(unit, quantity: quantity)) = \(servingSize)"
    }

    // MARK: - Nutrition

    private var nutritionSection: some View {
        LogFoodNutritionCard(
            calories: scaledCalories,
            fat: scaledFat,
            carbs: scaledCarbs,
            protein: scaledProtein,
            currentDayCalories: currentDayCalories,
            dailyGoal: goals.dailyCalories,
            accentColor: accentTheme.accentColor,
            cardColor: cardColor
        )
    }

    // MARK: - Micronutrients

    private var micronutrientSection: some View {
        VStack(alignment: .leading, spacing: OFJSpace.s8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Micronutrients")
                    .font(.headline)
                Spacer()
                Text("% of daily value")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, OFJSpace.s4)

            VStack(spacing: 0) {
                let keys = LogFoodPresentation.orderedMicronutrientKeys(
                    Array(editedMicros.keys)
                )
                ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                    if let baseValue = editedMicros[key],
                       let scaledValue = scaledMicronutrients[key] {
                        let known = KnownMicronutrients.find(key)
                        EditableMicroRow(
                            name: known?.name ?? key,
                            value: scaledValue.value,
                            unit: baseValue.unit,
                            dailyValue: known?.dailyValue,
                            accentColor: accentTheme.accentColor,
                            onValueChanged: { newValue in
                                editedMicros[key] = MicronutrientValue(
                                    value: newValue / micronutrientScaleFactor,
                                    unit: baseValue.unit
                                )
                            }
                        )

                        if index < keys.count - 1 {
                            Divider()
                                .padding(.leading, OFJSpace.s16)
                        }
                    }
                }
            }
            .logFoodCard(color: cardColor)
        }
    }

    // MARK: - Meal Picker

    private var mealPicker: some View {
        VStack(alignment: .leading, spacing: OFJSpace.s8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Log as")
                    .font(.headline)
                Spacer()
                Text("Suggested for \(AppPresentationDate.now.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, OFJSpace.s4)

            Picker("Meal Type", selection: mealTypeBinding) {
                ForEach(MealType.allCases) { meal in
                    Text(meal.rawValue.capitalized).tag(meal)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Log Button

    private var logButton: some View {
        Button(action: logFood) {
            Text(
                "Add to \(mealTypeForLog.rawValue.capitalized) · "
                    + "\(Int(scaledCalories.rounded())) kcal"
            )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, OFJSpace.s6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: OFJRadius.compactCard))
        .controlSize(.extraLarge)
        .tint(accentTheme.accentColor)
        .disabled(quantity <= 0)
        .accessibilityHint("Logs this amount to the selected meal")
    }

    private func logFood() {
        let entry = food.toNutritionEntry(mealType: mealTypeForLog)
        entry.calories = scaledCalories
        entry.protein = scaledProtein
        entry.carbs = scaledCarbs
        entry.fat = scaledFat
        entry.micronutrients = scaledMicronutrients
        // Persist the user's display unit as the new baseline for future edits
        // and repeat logs; NutritionStore retains the linked Food Bank ID.
        entry.servingQuantity = quantity
        entry.servingUnit = selectedUnit
        nutritionStore.log(entry, to: logDate)
        dismiss()
    }

    private var mealTypeBinding: Binding<MealType> {
        Binding {
            selectedMealType
        } set: { newValue in
            selectedMealType = newValue
            mealTypeWasEdited = true
        }
    }

    private var mealTypeForLog: MealType {
        mealTypeWasEdited ? selectedMealType : mealTimeSettings.mealType(for: AppPresentationDate.now)
    }

    private func applyDefaultMealTypeIfNeeded() {
        guard !didApplyDefaultMealType else { return }
        selectedMealType = mealTimeSettings.mealType(for: AppPresentationDate.now)
        didApplyDefaultMealType = true
    }

    // MARK: - Serving Section

    private var servingSection: some View {
        VStack(alignment: .leading, spacing: OFJSpace.s16) {
            HStack(spacing: OFJSpace.s8) {
                Text("Quantity")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: OFJSpace.s8)

                ZStack(alignment: .trailing) {
                    ScrollView(.horizontal) {
                        HStack(spacing: OFJSpace.s6) {
                            ForEach(
                                LogFoodPresentation.orderedUnits(
                                    availableUnits,
                                    baseUnit: converter.baseUnit
                                ),
                                id: \.self
                            ) { unit in
                                unitButton(unit)
                            }
                        }
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: UnitStripContentWidthKey.self,
                                    value: proxy.size.width
                                )
                            }
                        }
                        .padding(.trailing, showsUnitStripChevron ? OFJSpace.s16 : 0)
                    }
                    .scrollIndicators(.hidden)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: UnitStripViewportWidthKey.self,
                                value: proxy.size.width
                            )
                        }
                    }

                    if showsUnitStripChevron {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, OFJSpace.s16)
                            .frame(maxHeight: .infinity)
                            .background(
                                LinearGradient(
                                    colors: [.clear, cardColor, cardColor],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onPreferenceChange(UnitStripContentWidthKey.self) {
                    unitStripContentWidth = $0
                }
                .onPreferenceChange(UnitStripViewportWidthKey.self) {
                    unitStripViewportWidth = $0
                }
            }

            HStack(spacing: OFJSpace.s16) {
                HStack(spacing: 0) {
                    quantityAdjustmentButton(
                        systemImage: "minus",
                        accessibilityLabel: "Decrease quantity",
                        action: decrementQuantity
                    )

                    TextField("Amount", text: $quantityText)
                        .keyboardType(.decimalPad)
                        .font(.title2.weight(.bold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .frame(minWidth: 62)
                        .focused($quantityIsFocused)
                        .foregroundStyle(
                            quantityIsFocused ? Color.primary : Color.clear
                        )
                        .overlay {
                            if !quantityIsFocused {
                                Text(quantityText)
                                    .font(.title2.weight(.bold).monospacedDigit())
                                    .ofjNumericTextTransition(value: quantity)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: quantityText) { _, newValue in
                            if let value = Double(newValue), value > 0 {
                                quantity = value
                            }
                        }

                    quantityAdjustmentButton(
                        systemImage: "plus",
                        accessibilityLabel: "Increase quantity",
                        action: incrementQuantity
                    )
                }
                .frame(height: 56)
                .overlay {
                    RoundedRectangle(cornerRadius: OFJRadius.control)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: OFJSpace.s3) {
                    Text(LogFoodPresentation.unitLabel(selectedUnit, quantity: quantity))
                        .font(.subheadline.weight(.medium))
                    Text(quantityTotalText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .ofjNumericTextTransition(value: quantity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(OFJSpace.s16)
        .logFoodCard(color: cardColor)
    }

    private func unitButton(_ unit: String) -> some View {
        let isSelected = selectedUnit == unit
        return Button {
            selectUnit(unit)
        } label: {
            Text(LogFoodPresentation.unitPickerLabel(unit))
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .padding(.horizontal, OFJSpace.s12)
                .frame(minHeight: 36)
                .background(
                    isSelected ? accentTheme.accentColor : Color.secondary.opacity(0.09),
                    in: .rect(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func quantityAdjustmentButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                // The symbol remains visually compact while the button owns a
                // consistent full-height column. This makes the entire area
                // beside the amount field tappable, not just the glyph.
                .frame(width: 52)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .frame(maxHeight: .infinity)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(accessibilityLabel)
    }

    private var showsUnitStripChevron: Bool {
        LogFoodPresentation.shouldShowUnitOverflowIndicator(
            contentWidth: unitStripContentWidth,
            viewportWidth: unitStripViewportWidth
        )
    }

    private func selectUnit(_ newUnit: String) {
        guard selectedUnit != newUnit else { return }
        let converted = LogFoodPresentation.convertedQuantity(
            quantity,
            from: selectedUnit,
            to: newUnit,
            using: converter
        )
        selectedUnit = newUnit
        quantity = converted
        quantityText = formattedQuantity(converted)
    }

    private func incrementQuantity() {
        quantity = LogFoodPresentation.incrementedQuantity(
            quantity,
            unit: selectedUnit
        )
        quantityText = formattedQuantity(quantity)
    }

    private func decrementQuantity() {
        quantity = LogFoodPresentation.decrementedQuantity(
            quantity,
            unit: selectedUnit
        )
        quantityText = formattedQuantity(quantity)
    }

    private var quantityTotalText: String {
        if let grams = LogFoodPresentation.convertedAmount(
            quantity,
            from: selectedUnit,
            to: "g",
            using: converter
        ) {
            return "\(formattedQuantity(grams)) g total"
        }

        let baseAmount = LogFoodPresentation.convertedQuantity(
            quantity,
            from: selectedUnit,
            to: converter.baseUnit,
            using: converter
        )
        return "\(formattedQuantity(baseAmount)) "
            + "\(LogFoodPresentation.unitLabel(converter.baseUnit, quantity: baseAmount)) total"
    }

    /// Repeated logs should open exactly where the user left off. If mappings
    /// changed and the old unit is no longer valid, preserve the template
    /// quantity and unit rather than applying a partially compatible default.
    private func applyLastUsedServingIfNeeded() {
        guard !didApplyLastUsedServing else { return }
        didApplyLastUsedServing = true
        guard let last = nutritionStore.lastUsedServing(for: food),
              availableUnits.contains(last.unit) else {
            return
        }

        quantity = last.quantity
        quantityText = formattedQuantity(last.quantity)
        if selectedUnit != last.unit {
            selectedUnit = last.unit
        }
    }

    private func formattedQuantity(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
    }

    // MARK: - Serving Mappings

    private var servingMappingsSection: some View {
        VStack(alignment: .leading, spacing: OFJSpace.s8) {
            HStack {
                Text("Units for this food")
                    .font(.headline)
                Spacer()
                Button {
                    editingMappingIndex = nil
                    showAddMapping = true
                } label: {
                    Text("Add a unit")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(.horizontal, OFJSpace.s4)

            VStack(spacing: 0) {
                if unitRows.isEmpty {
                    Text("Add a conversion to use cups, grams, or another unit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(OFJSpace.s16)
                } else {
                    ForEach(Array(unitRows.enumerated()), id: \.element.id) { rowIndex, row in
                        if let mappingIndex = row.mappingIndex {
                            Button {
                                editingMappingIndex = mappingIndex
                                showAddMapping = true
                            } label: {
                                unitMappingRow(row, showsChevron: true)
                            }
                            .buttonStyle(.plain)
                        } else {
                            unitMappingRow(row, showsChevron: false)
                        }

                        if rowIndex < unitRows.count - 1 {
                            Divider()
                                .padding(.leading, OFJSpace.s16)
                        }
                    }
                }
            }
            .logFoodCard(color: cardColor)
        }
    }

    private func unitMappingRow(
        _ row: LogFoodUnitRow,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: OFJSpace.s12) {
            Text(row.from)
                .font(.subheadline.weight(.medium))
            Text("=")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Text(row.to)
                .font(.subheadline)
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, OFJSpace.s16)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private var unitRows: [LogFoodUnitRow] {
        var rows: [LogFoodUnitRow] = []

        if let servingSize = food.servingSize, !servingSize.isEmpty {
            let baseQuantity = food.servingQuantity ?? 1
            let baseUnit = food.servingUnit ?? "serving"
            rows.append(
                LogFoodUnitRow(
                    id: "base-\(baseQuantity)-\(baseUnit)-\(servingSize)",
                    from: "\(formattedQuantity(baseQuantity)) "
                        + LogFoodPresentation.unitLabel(baseUnit, quantity: baseQuantity),
                    to: servingSize,
                    mappingIndex: nil
                )
            )
        }

        for (index, mapping) in food.servingMappings.enumerated() {
            let row = LogFoodUnitRow(
                id: "mapping-\(index)-\(mapping.from.displayString)-\(mapping.to.displayString)",
                from: mapping.from.displayString,
                to: mapping.to.displayString,
                mappingIndex: index
            )
            let duplicate = rows.contains {
                $0.from.caseInsensitiveCompare(row.from) == .orderedSame
                    && $0.to.caseInsensitiveCompare(row.to) == .orderedSame
            }
            if !duplicate {
                rows.append(row)
            }
        }

        return rows
    }

    /// Appends a new serving mapping to the food and propagates to all linked entries.
    private func addMapping(_ mapping: ServingMapping) {
        nutritionStore.addMapping(mapping, to: food)
    }

    /// Replaces an existing mapping and propagates to all linked entries.
    private func updateMapping(at index: Int, with mapping: ServingMapping) {
        nutritionStore.replaceMapping(at: index, with: mapping, on: food)
    }

    // MARK: - Helpers

    /// Human-readable label for the food's origin
    private var sourceLabel: String {
        if food.kind == .composite {
            return "Composite Food"
        }

        return switch food.originalScanMode {
        case .label: "Label Scan"
        case .foodPhoto: "Food Photo"
        case .barcode: "Barcode Scan"
        case .manual: "Manual Entry"
        }
    }
}

struct LogFoodUnitRow: Identifiable, Hashable {
    let id: String
    let from: String
    let to: String
    let mappingIndex: Int?
}

/// Pure presentation rules for the Log Food surface. Keeping unit ordering,
/// pluralization, conversion, and progress math outside SwiftUI makes the
/// visual layer deterministic and independently testable.
enum LogFoodPresentation {
    private static let preferredMicronutrientOrder = [
        "saturated_fat",
        "sodium",
        "calcium",
        "vitamin_a",
        "iron",
        "potassium",
        "fiber",
        "cholesterol",
        "added_sugars",
    ]

    static func orderedUnits(_ units: [String], baseUnit: String) -> [String] {
        let preferred = [
            baseUnit,
            "serving",
            "cup",
            "g",
            "mL",
            "tbsp",
            "tsp",
            "oz",
            "kg",
            "lb",
        ]
        let unique = Array(Set(units))
        return unique.sorted { lhs, rhs in
            let leftIndex = preferred.firstIndex(of: lhs) ?? Int.max
            let rightIndex = preferred.firstIndex(of: rhs) ?? Int.max
            if leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    static func unitPickerLabel(_ unit: String) -> String {
        switch unit.lowercased() {
        case "g": "grams"
        case "ml": "mL"
        case "oz": "ounces"
        case "kg": "kilograms"
        case "lb": "pounds"
        case "serving": "servings"
        case "cup": "cups"
        default: unit
        }
    }

    static func unitLabel(_ unit: String, quantity: Double) -> String {
        guard abs(quantity - 1) > 0.000_1 else {
            return switch unit.lowercased() {
            case "g": "g"
            case "ml": "mL"
            case "oz": "oz"
            case "kg": "kg"
            case "lb": "lb"
            default: unit
            }
        }
        return unitPickerLabel(unit)
    }

    static func quantityStep(for unit: String) -> Double {
        switch unit.lowercased() {
        case "cup": 0.25
        case "tbsp", "tsp", "serving", "slice", "piece", "item": 1
        case "kg", "lb": 0.1
        default: 1
        }
    }

    static func shouldShowUnitOverflowIndicator(
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> Bool {
        viewportWidth > 0 && contentWidth > viewportWidth + 1
    }

    static func roundedQuantity(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func incrementedQuantity(_ quantity: Double, unit: String) -> Double {
        roundedQuantity(quantity + quantityStep(for: unit))
    }

    static func decrementedQuantity(_ quantity: Double, unit: String) -> Double {
        roundedQuantity(max(0, quantity - quantityStep(for: unit)))
    }

    static func convertedQuantity(
        _ quantity: Double,
        from sourceUnit: String,
        to targetUnit: String,
        using converter: ServingConverter
    ) -> Double {
        let sourceFactor = converter.factorFor(sourceUnit)
        let targetFactor = converter.factorFor(targetUnit)
        guard sourceFactor > 0, targetFactor > 0 else { return quantity }
        return roundedQuantity(quantity / sourceFactor * targetFactor)
    }

    static func convertedAmount(
        _ quantity: Double,
        from sourceUnit: String,
        to targetUnit: String,
        using converter: ServingConverter
    ) -> Double? {
        guard converter.availableUnits.contains(targetUnit) else { return nil }
        return convertedQuantity(
            quantity,
            from: sourceUnit,
            to: targetUnit,
            using: converter
        )
    }

    static func calorieShare(
        grams: Double,
        caloriesPerGram: Double,
        totalCalories: Double
    ) -> Double {
        guard totalCalories > 0 else { return 0 }
        return max(0, min((grams * caloriesPerGram) / totalCalories, 1))
    }

    static func orderedMicronutrientKeys(_ keys: [String]) -> [String] {
        keys.sorted { lhs, rhs in
            let leftID = KnownMicronutrients.find(lhs)?.id ?? lhs
            let rightID = KnownMicronutrients.find(rhs)?.id ?? rhs
            let leftIndex = preferredMicronutrientOrder.firstIndex(of: leftID) ?? Int.max
            let rightIndex = preferredMicronutrientOrder.firstIndex(of: rightID) ?? Int.max
            if leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            let leftName = KnownMicronutrients.find(lhs)?.name ?? lhs
            let rightName = KnownMicronutrients.find(rhs)?.name ?? rhs
            return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }
}

private struct UnitStripContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct UnitStripViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct LogFoodCardModifier: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .background(color, in: .rect(cornerRadius: OFJRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: OFJRadius.card)
                    .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
            }
    }
}

private extension View {
    func logFoodCard(color: Color) -> some View {
        modifier(LogFoodCardModifier(color: color))
    }
}

private struct LogFoodNutritionCard: View {
    let calories: Double
    let fat: Double
    let carbs: Double
    let protein: Double
    let currentDayCalories: Double
    let dailyGoal: Double
    let accentColor: Color
    let cardColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: OFJSpace.s16) {
            HStack(alignment: .firstTextBaseline, spacing: OFJSpace.s6) {
                Text(calories.formatted(.number.precision(.fractionLength(0))))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .ofjNumericTextTransition(value: calories)
                Text("kcal")
                    .font(.headline)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: OFJSpace.s14) {
                macroRow(
                    name: "Fat",
                    value: fat,
                    caloriesPerGram: 9,
                    color: accentColor
                )
                macroRow(
                    name: "Carbs",
                    value: carbs,
                    caloriesPerGram: 4,
                    color: accentColor.opacity(0.70)
                )
                macroRow(
                    name: "Protein",
                    value: protein,
                    caloriesPerGram: 4,
                    color: Color.secondary.opacity(0.38)
                )
            }

            Divider()

            VStack(spacing: OFJSpace.s9) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today after this")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(daySummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .ofjNumericTextTransition(value: currentDayCalories + calories)
                }
                dayProgress
            }
        }
        .padding(OFJSpace.s16)
        .logFoodCard(color: cardColor)
        .accessibilityElement(children: .contain)
    }

    private func macroRow(
        name: String,
        value: Double,
        caloriesPerGram: Double,
        color: Color
    ) -> some View {
        let share = LogFoodPresentation.calorieShare(
            grams: value,
            caloriesPerGram: caloriesPerGram,
            totalCalories: calories
        )
        return VStack(spacing: OFJSpace.s6) {
            HStack(spacing: OFJSpace.s8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(formattedMacro(value)) g")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .ofjNumericTextTransition(value: value)
                Text("\(Int((share * 100).rounded()))% of its calories")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .ofjNumericTextTransition(value: share)
            }
            ProgressView(value: share)
                .tint(color)
                .accessibilityLabel(name)
                .accessibilityValue(
                    "\(formattedMacro(value)) grams, \(Int((share * 100).rounded())) percent of calories"
                )
        }
    }

    private var daySummary: String {
        guard dailyGoal > 0 else {
            return "\(Int((currentDayCalories + calories).rounded())) kcal"
        }
        let after = currentDayCalories + calories
        let percentage = Int((after / dailyGoal * 100).rounded())
        return "\(Int(after.rounded())) / \(Int(dailyGoal.rounded())) · \(percentage)%"
    }

    private var dayProgress: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let safeGoal = max(dailyGoal, 1)
            let currentFraction = min(max(currentDayCalories / safeGoal, 0), 1)
            let afterFraction = min(max((currentDayCalories + calories) / safeGoal, 0), 1)
            let addedFraction = max(afterFraction - currentFraction, 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.10))
                Capsule()
                    .fill(Color.secondary.opacity(0.24))
                    .frame(width: width * currentFraction)
                Capsule()
                    .fill(accentColor)
                    .frame(width: width * addedFraction)
                    .offset(x: width * currentFraction)
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Daily calorie total after logging")
        .accessibilityValue(daySummary)
    }

    private func formattedMacro(_ value: Double) -> String {
        value.formatted(
            .number.precision(
                .fractionLength(value.rounded() == value ? 0 : 1)
            )
        )
    }
}

private struct LogFoodHeaderIcon: View {
    let food: SavedFood
    let useGeneratedIconImages: Bool
    let surfaceColor: Color

    @ScaledMetric(relativeTo: .headline) private var imageSize: CGFloat = 62
    @ScaledMetric(relativeTo: .headline) private var emojiSize: CGFloat = 34

    var body: some View {
        if prefersGeneratedImage, let image = generatedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: imageSize, height: imageSize)
                .clipShape(.rect(cornerRadius: OFJRadius.compactCard))
                .accessibilityHidden(true)
        } else if let emoji = food.normalizedEmoji {
            Text(emoji)
                .font(.system(size: emojiSize))
                .frame(width: imageSize, height: imageSize)
                .background(surfaceColor, in: .rect(cornerRadius: OFJRadius.compactCard))
                .accessibilityHidden(true)
        } else if let image = generatedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: imageSize, height: imageSize)
                .clipShape(.rect(cornerRadius: OFJRadius.compactCard))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "fork.knife")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: imageSize, height: imageSize)
                .background(surfaceColor, in: .rect(cornerRadius: OFJRadius.compactCard))
                .accessibilityHidden(true)
        }
    }

    private var prefersGeneratedImage: Bool {
        useGeneratedIconImages || food.normalizedEmoji == nil
    }

    private var generatedImage: UIImage? {
        guard let data = food.generatedIconImageData else { return nil }
        return UIImage(data: data)
    }
}



// MARK: - Add Serving Mapping Sheet

/// A compact form for defining or editing a unit conversion for a food.
/// For example: "1 cup → 244 g" means the user can later enter "1 cup"
/// in the quantity picker and the app will scale macros accordingly.
/// The caller receives the completed `ServingMapping` via the `onSave` closure.
/// Internal (not private) so EditEntryView can reuse the same sheet.
struct AddServingMappingSheet: View {
    @Environment(\.dismiss) private var dismiss

    // Callback — parent handles the actual model mutation
    let onSave: (ServingMapping) -> Void

    /// Optional existing mapping to edit. When nil, the sheet is in "add" mode.
    let existing: ServingMapping?

    // ── From side ─────────────────────────────────────────────────
    @State private var fromValue: String
    @State private var fromUnit: String

    // ── To side ───────────────────────────────────────────────────
    @State private var toValue: String
    @State private var toUnit: String

    /// Convenience init for adding a new mapping (backward-compatible call site)
    init(onAdd: @escaping (ServingMapping) -> Void) {
        self.onSave = onAdd
        self.existing = nil
        _fromValue = State(initialValue: "1")
        _fromUnit = State(initialValue: "serving")
        _toValue = State(initialValue: "")
        _toUnit = State(initialValue: "g")
    }

    /// Init for editing an existing mapping — pre-fills fields
    init(existing: ServingMapping, onSave: @escaping (ServingMapping) -> Void) {
        self.onSave = onSave
        self.existing = existing
        let fv = existing.from.value
        _fromValue = State(initialValue: fv.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", fv) : String(format: "%.2f", fv))
        _fromUnit = State(initialValue: existing.from.unit)
        let tv = existing.to.value
        _toValue = State(initialValue: tv.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", tv) : String(format: "%.2f", tv))
        _toUnit = State(initialValue: existing.to.unit)
    }

    private var isEditing: Bool { existing != nil }

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
            .navigationTitle(isEditing ? "Edit Unit Mapping" : "Add Unit Mapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let mapping = ServingMapping(
                            from: ServingAmount(value: Double(fromValue) ?? 1, unit: fromUnit.trimmingCharacters(in: .whitespaces)),
                            to: ServingAmount(value: Double(toValue) ?? 0, unit: toUnit.trimmingCharacters(in: .whitespaces))
                        )
                        onSave(mapping)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
    }
}

// MARK: - Editable Micro Row

private struct EditableMicroRow: View {
    let name: String
    let value: Double
    let unit: String
    let dailyValue: Double?
    let accentColor: Color
    let onValueChanged: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var progress: Double {
        guard let dv = dailyValue, dv > 0 else { return 0 }
        return min(value / dv, 1.0)
    }

    private var percentText: String {
        guard let dv = dailyValue, dv > 0 else { return "—" }
        return "\(Int((value / dv) * 100))%"
    }

    private var highlightsProgress: Bool {
        guard dailyValue != nil else { return false }
        return progress >= 0.20
    }

    var body: some View {
        VStack(spacing: OFJSpace.s8) {
            HStack(spacing: OFJSpace.s8) {
                Text(name)
                    .font(.subheadline)
                Spacer()

                HStack(spacing: 2) {
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .frame(minWidth: 48, idealWidth: 58, maxWidth: 68)
                        .focused($isFocused)
                        .onChange(of: text) { _, newVal in
                            if let d = Double(newVal), d >= 0 {
                                onValueChanged(d)
                            }
                        }
                        .onChange(of: isFocused) { _, focused in
                            if !focused {
                                text = formattedValue
                            }
                        }
                        .accessibilityLabel(name)
                        .accessibilityValue("\(formattedValue) \(unit)")
                        .accessibilityHint("Double tap to edit this amount")
                    Text(unit)
                        .font(.subheadline)
                }

                Text(percentText)
                    .font(.caption)
                    .foregroundStyle(
                        highlightsProgress
                            ? accentColor
                            : Color.secondary.opacity(0.55)
                    )
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                    .ofjNumericTextTransition(value: value)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.10))
                    if dailyValue != nil {
                        Capsule()
                            .fill(
                                highlightsProgress
                                    ? accentColor
                                    : Color.secondary.opacity(0.24)
                            )
                            .frame(width: proxy.size.width * progress)
                            .animation(.easeInOut, value: progress)
                    }
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, OFJSpace.s16)
        .padding(.vertical, OFJSpace.s12)
        .onAppear {
            text = formattedValue
        }
        .onChange(of: value) {
            guard !isFocused else { return }
            text = formattedValue
        }
    }

    private var formattedValue: String {
        value.formatted(
            .number.precision(
                .fractionLength(value.rounded() == value ? 0 : 1)
            )
        )
    }
}
