// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData

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

    init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
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
        originalScanMode: ScanMode = .manual
    ) {
        self.id = id
        self.name = name
        self.brand = brand
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
    }
}

// MARK: - Conversion Helpers

extension SavedFood {
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
}
