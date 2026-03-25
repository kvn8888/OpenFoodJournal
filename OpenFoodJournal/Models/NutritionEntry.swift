// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData

@Model
final class NutritionEntry {
    // CloudKit requires all stored properties to have default values.
    // The init() still overrides these; defaults are only used when CloudKit
    // materializes a record before all fields arrive.
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var name: String = ""
    var mealType: MealType = MealType.snack
    var scanMode: ScanMode = ScanMode.manual
    var confidence: Double?

    @Attribute(.externalStorage)
    var sourceImage: Data?

    // Core macros — always required
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0

    // Dynamic micronutrients — flexible key-value store.
    // Keys are nutrient names (e.g. "Fiber", "Vitamin A", "Sodium").
    // Values are MicronutrientValue (amount + unit).
    // SwiftData serializes this as a JSON blob, so new nutrients from Gemini
    // are added automatically without any schema migration.
    var micronutrients: [String: MicronutrientValue] = [:]

    // Serving info
    var servingSize: String?           // Display label (e.g. "1 cup (228g)") — legacy/display
    var servingsPerContainer: Double?
    var brand: String?                 // Product brand, separate from food name

    // Structured serving — canonical measurement for one serving.
    // Uses the ServingSize enum (mass/volume/both) with values in grams/mL.
    // All unit conversions (g→oz, mL→cups, etc.) are derived from this.
    var serving: ServingSize?

    // How many servings the user logged (e.g. 2.5 servings).
    // Macros on this entry = base macros × servingCount.
    var servingCount: Double = 1.0

    // Legacy fields — kept for backward compatibility with existing data.
    // New entries set these from the serving enum; old entries may have these only.
    var servingQuantity: Double?
    var servingUnit: String?

    // Per-food unit mappings — e.g. [{ from: 1 cup, to: 244 g }]
    // Lets the app convert between custom units (pieces, slices, etc.)
    var servingMappings: [ServingMapping] = []

    // How long the scan took (end-to-end from image upload to parsed result), in milliseconds.
    // Nil for manual entries. Used to track optimization progress.
    var scanDurationMs: Int?

    // Inverse relationship
    var dailyLog: DailyLog?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        name: String,
        mealType: MealType = .snack,
        scanMode: ScanMode = .manual,
        confidence: Double? = nil,
        sourceImage: Data? = nil,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        micronutrients: [String: MicronutrientValue] = [:],
        servingSize: String? = nil,
        servingsPerContainer: Double? = nil,
        brand: String? = nil,
        serving: ServingSize? = nil,
        servingCount: Double = 1.0,
        servingQuantity: Double? = nil,
        servingUnit: String? = nil,
        servingMappings: [ServingMapping] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.mealType = mealType
        self.scanMode = scanMode
        self.confidence = confidence
        self.sourceImage = sourceImage
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.micronutrients = micronutrients
        self.servingSize = servingSize
        self.servingsPerContainer = servingsPerContainer
        self.brand = brand
        self.serving = serving
        self.servingCount = servingCount
        self.servingQuantity = servingQuantity
        self.servingUnit = servingUnit
        self.servingMappings = servingMappings
    }
}

// MARK: - Convenience

extension NutritionEntry {
    /// AI confidence as an integer percentage (e.g. 0.97 → 97)
    var confidencePercent: Int? {
        guard let c = confidence else { return nil }
        return Int(c * 100)
    }

    /// Helper to get a micronutrient value by name, returns nil if not present
    func micronutrient(_ name: String) -> MicronutrientValue? {
        micronutrients[name]
    }

    /// Helper to set a micronutrient value by name
    func setMicronutrient(_ name: String, value: Double, unit: String) {
        micronutrients[name] = MicronutrientValue(value: value, unit: unit)
    }

    /// Sorted micronutrient keys for consistent display order
    var sortedMicronutrientNames: [String] {
        micronutrients.keys.sorted()
    }
}
