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
    var id: UUID
    var name: String
    var brand: String?             // Product brand, separate from name
    var createdAt: Date

    // Core macros — always required (same four as NutritionEntry)
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double

    // Dynamic micronutrients — same flexible dictionary as NutritionEntry.
    // When a user saves a scanned label with "Vitamin A: 300 mcg",
    // that nutrient carries over to the saved food template.
    var micronutrients: [String: MicronutrientValue]

    // Serving info
    var servingSize: String?               // Display label (backward compat)
    var servingsPerContainer: Double?
    var servingQuantity: Double?           // Numeric serving amount (e.g. 1.0)
    var servingUnit: String?               // Unit (e.g. "cup", "g", "piece")
    var servingMappings: [ServingMapping]   // Per-food unit conversions

    // Optional photo from the original scan
    @Attribute(.externalStorage)
    var sourceImage: Data?

    // How this food was originally captured (label scan, food photo, or manual)
    var originalScanMode: ScanMode

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
        servingQuantity: Double? = nil,
        servingUnit: String? = nil,
        servingMappings: [ServingMapping] = [],
        sourceImage: Data? = nil,
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
        self.servingQuantity = servingQuantity
        self.servingUnit = servingUnit
        self.servingMappings = servingMappings
        self.sourceImage = sourceImage
        self.originalScanMode = originalScanMode
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
            servingQuantity: entry.servingQuantity,
            servingUnit: entry.servingUnit,
            servingMappings: entry.servingMappings,
            sourceImage: entry.sourceImage,
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
            sourceImage: sourceImage,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            micronutrients: micronutrients,
            servingSize: servingSize,
            servingsPerContainer: servingsPerContainer,
            brand: brand,
            servingQuantity: servingQuantity,
            servingUnit: servingUnit,
            servingMappings: servingMappings
        )
    }
}
