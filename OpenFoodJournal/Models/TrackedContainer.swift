// OpenFoodJournal — TrackedContainer
// Represents a food container that the user is eating from over time.
// The user weighs the container at the start, eats from it over days,
// then enters the final weight to derive total consumed nutrition.
// AGPL-3.0 License

import Foundation
import SwiftData

/// A food container being tracked over time.
///
/// ## Flow
/// 1. User scans / creates a food (e.g. Cheerios: 140 cal per 39g serving)
/// 2. User weighs the full container on a scale → records startWeight (e.g. 500g)
/// 3. User eats from the container over multiple days
/// 4. User weighs the container again → records finalWeight (e.g. 200g)
/// 5. App calculates: consumed = 500 - 200 = 300g
/// 6. App derives nutrition: (300g / 39g per serving) × nutrients
///
/// The container weight (box/bag) cancels out since both measurements include it.
@Model
final class TrackedContainer {
    // CloudKit requires all stored properties to have default values.
    var id: UUID = UUID()

    // ── Food Reference ────────────────────────────────────────────
    // Snapshot the food's nutrition at the time of tracking, so changes
    // to the SavedFood don't retroactively affect container math.
    var foodName: String = ""
    var foodBrand: String?

    // Nutrition per serving — copied from the food at tracking time
    var caloriesPerServing: Double = 0
    var proteinPerServing: Double = 0
    var carbsPerServing: Double = 0
    var fatPerServing: Double = 0
    var micronutrientsPerServing: [String: MicronutrientValue] = [:]

    // The serving size in grams — critical for weight-based math
    // e.g. if label says "39g per serving", this is 39.0
    var gramsPerServing: Double = 0

    // ── Weight Tracking ───────────────────────────────────────────
    // Both weights include the container itself; it cancels out in the diff.
    var startWeight: Double = 0          // Weight at start (in grams), including container
    var finalWeight: Double?         // Weight when done (in grams), nil if still active

    // ── Dates ─────────────────────────────────────────────────────
    var startDate: Date = Date()
    var completedDate: Date?         // Set when finalWeight is entered

    // ── Optional: link to the SavedFood for re-tracking ──────────
    // Not a SwiftData relationship to avoid cascade issues.
    // If the user deletes the SavedFood, the container still works
    // because we snapshotted the nutrition data above.
    var savedFoodID: UUID?

    init(
        id: UUID = UUID(),
        foodName: String,
        foodBrand: String? = nil,
        caloriesPerServing: Double,
        proteinPerServing: Double,
        carbsPerServing: Double,
        fatPerServing: Double,
        micronutrientsPerServing: [String: MicronutrientValue] = [:],
        gramsPerServing: Double,
        startWeight: Double,
        startDate: Date = .now,
        savedFoodID: UUID? = nil
    ) {
        self.id = id
        self.foodName = foodName
        self.foodBrand = foodBrand
        self.caloriesPerServing = caloriesPerServing
        self.proteinPerServing = proteinPerServing
        self.carbsPerServing = carbsPerServing
        self.fatPerServing = fatPerServing
        self.micronutrientsPerServing = micronutrientsPerServing
        self.gramsPerServing = gramsPerServing
        self.startWeight = startWeight
        self.startDate = startDate
        self.savedFoodID = savedFoodID
    }
}

// MARK: - Computed Properties

extension TrackedContainer {
    /// Whether this container is still being tracked (no final weight entered yet)
    var isActive: Bool {
        finalWeight == nil
    }

    /// Total grams of food consumed (start - final). Nil if still active.
    var consumedGrams: Double? {
        guard let finalWeight else { return nil }
        return max(0, startWeight - finalWeight)
    }

    /// Number of servings consumed, based on grams consumed ÷ grams per serving.
    var consumedServings: Double? {
        guard let grams = consumedGrams, gramsPerServing > 0 else { return nil }
        return grams / gramsPerServing
    }

    /// Total calories consumed from this container
    var consumedCalories: Double? {
        guard let servings = consumedServings else { return nil }
        return servings * caloriesPerServing
    }

    /// Total protein consumed from this container
    var consumedProtein: Double? {
        guard let servings = consumedServings else { return nil }
        return servings * proteinPerServing
    }

    /// Total carbs consumed from this container
    var consumedCarbs: Double? {
        guard let servings = consumedServings else { return nil }
        return servings * carbsPerServing
    }

    /// Total fat consumed from this container
    var consumedFat: Double? {
        guard let servings = consumedServings else { return nil }
        return servings * fatPerServing
    }

    /// All consumed micronutrients, scaled by number of servings consumed
    var consumedMicronutrients: [String: MicronutrientValue]? {
        guard let servings = consumedServings else { return nil }
        var result: [String: MicronutrientValue] = [:]
        for (name, micro) in micronutrientsPerServing {
            result[name] = MicronutrientValue(
                value: micro.value * servings,
                unit: micro.unit
            )
        }
        return result
    }

    /// Creates a NutritionEntry representing the total consumed from this container.
    /// Call this when the user completes the container to log the consumed amount.
    func toNutritionEntry(mealType: MealType = .snack) -> NutritionEntry? {
        guard let servings = consumedServings else { return nil }
        return NutritionEntry(
            name: foodName,
            mealType: mealType,
            scanMode: .manual,
            calories: caloriesPerServing * servings,
            protein: proteinPerServing * servings,
            carbs: carbsPerServing * servings,
            fat: fatPerServing * servings,
            micronutrients: consumedMicronutrients ?? [:],
            brand: foodBrand
        )
    }
}

// MARK: - Factory

extension TrackedContainer {
    /// Creates a TrackedContainer from a SavedFood.
    /// Requires gramsPerServing — the user must have a weight-based serving defined.
    static func from(
        _ food: SavedFood,
        startWeight: Double,
        gramsPerServing: Double
    ) -> TrackedContainer {
        TrackedContainer(
            foodName: food.name,
            foodBrand: food.brand,
            caloriesPerServing: food.calories,
            proteinPerServing: food.protein,
            carbsPerServing: food.carbs,
            fatPerServing: food.fat,
            micronutrientsPerServing: food.micronutrients,
            gramsPerServing: gramsPerServing,
            startWeight: startWeight,
            savedFoodID: food.id
        )
    }
}
