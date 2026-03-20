// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation
import SwiftData

@Model
final class NutritionEntry {
    var id: UUID
    var timestamp: Date
    var name: String
    var mealType: MealType
    var scanMode: ScanMode
    var confidence: Double?

    @Attribute(.externalStorage)
    var sourceImage: Data?

    // Core macros
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double

    // Extended macros (populated primarily from label scans)
    var fiber: Double?
    var sugar: Double?
    var sodium: Double?
    var cholesterol: Double?
    var saturatedFat: Double?
    var transFat: Double?
    var servingSize: String?
    var servingsPerContainer: Double?

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
        fiber: Double? = nil,
        sugar: Double? = nil,
        sodium: Double? = nil,
        cholesterol: Double? = nil,
        saturatedFat: Double? = nil,
        transFat: Double? = nil,
        servingSize: String? = nil,
        servingsPerContainer: Double? = nil
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
        self.fiber = fiber
        self.sugar = sugar
        self.sodium = sodium
        self.cholesterol = cholesterol
        self.saturatedFat = saturatedFat
        self.transFat = transFat
        self.servingSize = servingSize
        self.servingsPerContainer = servingsPerContainer
    }
}

// MARK: - Convenience

extension NutritionEntry {
    var confidencePercent: Int? {
        guard let c = confidence else { return nil }
        return Int(c * 100)
    }
}
