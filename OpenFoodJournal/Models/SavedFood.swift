// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData

enum SavedFoodKind: String, Codable, CaseIterable, Sendable {
    case single
    case composite
    case calculator
}

struct CompositeNutritionTotals {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var micronutrients: [String: MicronutrientValue] = [:]
}

struct CompositeIngredientSnapshot: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var brand: String?
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var micronutrients: [String: MicronutrientValue] = [:]
    var servingSize: String?
    var servingsPerContainer: Double?
    var serving: ServingSize?
    var servingQuantity: Double?
    var servingUnit: String?
    var servingMappings: [ServingMapping] = []
    var selectedQuantity: Double = 1
    var selectedUnit: String = "serving"

    init() {}

    init(food: SavedFood) {
        let quantity = food.servingQuantity ?? 1
        let unit = food.servingUnit ?? "serving"

        id = UUID()
        name = food.name
        brand = food.brand
        calories = food.calories
        protein = food.protein
        carbs = food.carbs
        fat = food.fat
        micronutrients = food.micronutrients
        servingSize = food.servingSize
        servingsPerContainer = food.servingsPerContainer
        serving = food.serving
        servingQuantity = food.servingQuantity
        servingUnit = food.servingUnit
        servingMappings = food.servingMappings
        selectedQuantity = quantity
        selectedUnit = unit
    }

    var baseQuantity: Double {
        max(servingQuantity ?? 1, 0.01)
    }

    var baseUnit: String {
        servingUnit ?? "serving"
    }

    var converter: ServingConverter {
        ServingConverter(
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            quantity: baseQuantity,
            unit: baseUnit,
            serving: serving,
            mappings: servingMappings
        )
    }

    var availableUnits: [String] {
        var units = Set(converter.availableUnits)
        units.insert(selectedUnit)
        return units.sorted()
    }

    var selectedFactor: Double {
        selectedQuantity / converter.factorFor(selectedUnit) / converter.baseQuantity
    }

    var scaledNutrition: CompositeNutritionTotals {
        let factor = selectedFactor
        var totals = CompositeNutritionTotals(
            calories: converter.scaledCalories(quantity: selectedQuantity, unit: selectedUnit),
            protein: converter.scaledProtein(quantity: selectedQuantity, unit: selectedUnit),
            carbs: converter.scaledCarbs(quantity: selectedQuantity, unit: selectedUnit),
            fat: converter.scaledFat(quantity: selectedQuantity, unit: selectedUnit)
        )

        for (name, micro) in micronutrients {
            totals.micronutrients[name] = MicronutrientValue(
                value: micro.value * factor,
                unit: micro.unit
            )
        }

        return totals
    }
}

struct CalculatorPortionOption: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var label: String = ""
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var micronutrients: [String: MicronutrientValue] = [:]

    init() {}

    init(
        id: UUID = UUID(),
        label: String,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        micronutrients: [String: MicronutrientValue] = [:]
    ) {
        self.id = id
        self.label = label
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.micronutrients = micronutrients
    }

    func scaled(by quantity: Double) -> CompositeNutritionTotals {
        let factor = max(quantity, 0)
        var totals = CompositeNutritionTotals(
            calories: calories * factor,
            protein: protein * factor,
            carbs: carbs * factor,
            fat: fat * factor
        )

        for (name, micro) in micronutrients {
            totals.micronutrients[name] = MicronutrientValue(
                value: micro.value * factor,
                unit: micro.unit
            )
        }

        return totals
    }

    func scaledPortion(by factor: Double, label: String) -> CalculatorPortionOption {
        CalculatorPortionOption(
            label: label,
            calories: calories * factor,
            protein: protein * factor,
            carbs: carbs * factor,
            fat: fat * factor,
            micronutrients: micronutrients.mapValues {
                MicronutrientValue(value: $0.value * factor, unit: $0.unit)
            }
        )
    }
}

struct CalculatorIngredient: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var note: String?
    var portions: [CalculatorPortionOption] = []

    init() {}

    init(
        id: UUID = UUID(),
        name: String,
        note: String? = nil,
        portions: [CalculatorPortionOption] = []
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.portions = portions
    }
}

struct CalculatorSelection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var ingredientID: UUID = UUID()
    var portionID: UUID = UUID()
    var quantity: Double = 1

    init() {}

    init(
        id: UUID = UUID(),
        ingredientID: UUID,
        portionID: UUID,
        quantity: Double = 1
    ) {
        self.id = id
        self.ingredientID = ingredientID
        self.portionID = portionID
        self.quantity = quantity
    }
}

/// A saved food template in the user's "Personal Food Bank".
/// Users can save any scanned or manually entered food here for quick re-logging.
/// Unlike NutritionEntry (which belongs to a DailyLog), SavedFood is standalone —
/// it's a reusable template that can be logged to any date/meal with one tap.
@Model
final class SavedFood {
    // CloudKit requires all stored properties to have default values.
    var id: UUID = UUID()
    var name: String = ""
    var brand: String?             // Product brand, separate from name
    var emoji: String?             // Optional user-visible Food Bank icon
    var createdAt: Date = Date()

    // Core macros — always required (same four as NutritionEntry)
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0

    // Dynamic micronutrients — same flexible dictionary as NutritionEntry.
    // When a user saves a scanned label with "Vitamin A: 300 mcg",
    // that nutrient carries over to the saved food template.
    var micronutrients: [String: MicronutrientValue] = [:]

    // Serving info
    var servingSize: String?               // Display label (backward compat)
    var servingsPerContainer: Double?

    // Structured serving — canonical measurement for one serving (mass/volume/both)
    var serving: ServingSize?

    // Legacy fields — kept for backward compat with old data
    var servingQuantity: Double?
    var servingUnit: String?
    var servingMappings: [ServingMapping] = []

    // How this food was originally captured (label scan, food photo, or manual)
    var originalScanMode: ScanMode = ScanMode.manual

    // Tracks when this food was last used (logged or saved).
    // Defaults to createdAt so newly saved foods surface to the top of "Last Used" sort.
    var lastUsedAt: Date = Date()

    // Cosmetic Food Bank archive state. Archived foods stay in SwiftData and remain searchable.
    var archivedAt: Date?

    // Composite foods snapshot ingredient nutrition instead of referencing source SavedFoods.
    var kind: SavedFoodKind = SavedFoodKind.single
    var compositeIngredients: [CompositeIngredientSnapshot] = []
    var calculatorIngredients: [CalculatorIngredient] = []

    init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        emoji: String? = nil,
        createdAt: Date = .now,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        micronutrients: [String: MicronutrientValue] = [:],
        servingSize: String? = nil,
        servingsPerContainer: Double? = nil,
        serving: ServingSize? = nil,
        servingQuantity: Double? = nil,
        servingUnit: String? = nil,
        servingMappings: [ServingMapping] = [],
        originalScanMode: ScanMode = .manual,
        archivedAt: Date? = nil,
        kind: SavedFoodKind = SavedFoodKind.single,
        compositeIngredients: [CompositeIngredientSnapshot] = [],
        calculatorIngredients: [CalculatorIngredient] = []
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.emoji = emoji
        self.createdAt = createdAt
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.micronutrients = micronutrients
        self.servingSize = servingSize
        self.servingsPerContainer = servingsPerContainer
        self.serving = serving
        self.servingQuantity = servingQuantity
        self.servingUnit = servingUnit
        self.servingMappings = servingMappings
        self.originalScanMode = originalScanMode
        self.lastUsedAt = createdAt  // New foods count as "just used" for sort ordering
        self.archivedAt = archivedAt
        self.kind = kind
        self.compositeIngredients = compositeIngredients
        self.calculatorIngredients = calculatorIngredients
    }
}

// MARK: - Conversion Helpers

extension SavedFood {
    static let foodBankArchiveAgeInDays = 14

    static func foodBankArchiveCutoff(now: Date = .now) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: -foodBankArchiveAgeInDays,
            to: now
        ) ?? now
    }

    var isArchivedInFoodBank: Bool {
        archivedAt != nil || lastUsedAt < Self.foodBankArchiveCutoff()
    }

    func archiveForFoodBank(now: Date = .now) {
        archivedAt = now
    }

    func restoreFromFoodBankArchive(now: Date = .now) {
        archivedAt = nil
        lastUsedAt = now
    }

    func markLoggedForFoodBank(now: Date = .now) {
        lastUsedAt = now
        archivedAt = nil
    }

    var normalizedEmoji: String? {
        guard let emoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines),
              !emoji.isEmpty else {
            return nil
        }
        return emoji
    }

    var needsFoodBankEmoji: Bool {
        normalizedEmoji == nil
    }

    static func compositeTotals(for ingredients: [CompositeIngredientSnapshot]) -> CompositeNutritionTotals {
        var totals = CompositeNutritionTotals()

        for ingredient in ingredients {
            let scaled = ingredient.scaledNutrition
            totals.calories += scaled.calories
            totals.protein += scaled.protein
            totals.carbs += scaled.carbs
            totals.fat += scaled.fat

            for (name, micro) in scaled.micronutrients {
                mergeMicronutrient(name: name, value: micro, into: &totals.micronutrients)
            }
        }

        return totals
    }

    func refreshCompositeNutrition() {
        guard kind == .composite else { return }

        let totals = Self.compositeTotals(for: compositeIngredients)
        calories = totals.calories
        protein = totals.protein
        carbs = totals.carbs
        fat = totals.fat
        micronutrients = totals.micronutrients
        servingSize = "1 portion"
        servingsPerContainer = nil
        serving = nil
        servingQuantity = 1
        servingUnit = "portion"
        servingMappings = []
        originalScanMode = .manual
    }

    func refreshCalculatorNutrition() {
        guard kind == .calculator else { return }

        calories = 0
        protein = 0
        carbs = 0
        fat = 0
        micronutrients = [:]
        servingSize = "\(calculatorIngredients.count) ingredient\(calculatorIngredients.count == 1 ? "" : "s")"
        servingsPerContainer = nil
        serving = nil
        servingQuantity = 1
        servingUnit = "build"
        servingMappings = []
        originalScanMode = .manual
    }

    static func calculatorTotals(
        for ingredients: [CalculatorIngredient],
        selections: [CalculatorSelection]
    ) -> CompositeNutritionTotals {
        var totals = CompositeNutritionTotals()

        for selection in selections {
            guard let resolved = resolve(selection, in: ingredients) else { continue }
            let scaled = resolved.portion.scaled(by: selection.quantity)
            totals.calories += scaled.calories
            totals.protein += scaled.protein
            totals.carbs += scaled.carbs
            totals.fat += scaled.fat

            for (name, micro) in scaled.micronutrients {
                mergeMicronutrient(name: name, value: micro, into: &totals.micronutrients)
            }
        }

        return totals
    }

    static func calculatorSelectionSummary(
        for ingredients: [CalculatorIngredient],
        selections: [CalculatorSelection]
    ) -> String {
        selections.compactMap { selection in
            guard let resolved = resolve(selection, in: ingredients) else { return nil }
            let quantityPrefix = selection.quantity == 1
                ? ""
                : "\(formatQuantity(selection.quantity))x "
            return "\(quantityPrefix)\(resolved.ingredient.name) (\(resolved.portion.label))"
        }
        .joined(separator: ", ")
    }

    static func missingCalculatorSelectionCount(
        for ingredients: [CalculatorIngredient],
        selections: [CalculatorSelection]
    ) -> Int {
        selections.filter { resolve($0, in: ingredients) == nil }.count
    }

    private static func resolve(
        _ selection: CalculatorSelection,
        in ingredients: [CalculatorIngredient]
    ) -> (ingredient: CalculatorIngredient, portion: CalculatorPortionOption)? {
        guard let ingredient = ingredients.first(where: { $0.id == selection.ingredientID }),
              let portion = ingredient.portions.first(where: { $0.id == selection.portionID }) else {
            return nil
        }

        return (ingredient, portion)
    }

    private static func formatQuantity(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
    }

    /// Creates a SavedFood from an existing NutritionEntry (e.g. "Save to Food Bank" button).
    /// Copies all nutrition data including serving mappings, but strips the daily-log relationship.
    convenience init(from entry: NutritionEntry) {
        self.init(
            name: entry.name,
            brand: entry.brand,
            calories: entry.calories,
            protein: entry.protein,
            carbs: entry.carbs,
            fat: entry.fat,
            micronutrients: entry.micronutrients,
            servingSize: entry.servingSize,
            servingsPerContainer: entry.servingsPerContainer,
            serving: entry.serving,
            servingQuantity: entry.servingQuantity,
            servingUnit: entry.servingUnit,
            servingMappings: entry.servingMappings,
            originalScanMode: entry.scanMode
        )
    }

    /// Creates a new NutritionEntry from this saved food, ready to be logged.
    /// The caller sets the mealType and date before inserting into SwiftData.
    func toNutritionEntry(mealType: MealType = .snack) -> NutritionEntry {
        NutritionEntry(
            name: name,
            mealType: mealType,
            scanMode: originalScanMode,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            micronutrients: micronutrients,
            servingSize: servingSize,
            servingsPerContainer: servingsPerContainer,
            brand: brand,
            serving: serving,
            servingQuantity: servingQuantity,
            servingUnit: servingUnit,
            servingMappings: servingMappings,
            savedFoodID: id
        )
    }

    private static func mergeMicronutrient(
        name: String,
        value: MicronutrientValue,
        into totals: inout [String: MicronutrientValue]
    ) {
        guard let existing = totals[name] else {
            totals[name] = value
            return
        }

        if existing.unit == value.unit {
            totals[name] = MicronutrientValue(
                value: existing.value + value.value,
                unit: existing.unit
            )
        } else {
            let qualifiedName = "\(name) (\(value.unit))"
            if let qualified = totals[qualifiedName], qualified.unit == value.unit {
                totals[qualifiedName] = MicronutrientValue(
                    value: qualified.value + value.value,
                    unit: value.unit
                )
            } else {
                totals[qualifiedName] = value
            }
        }
    }
}
