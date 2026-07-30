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
///    Optionally, they also record the empty container tare (e.g. 350g), making
///    the initial food weight visible (500g - 350g = 150g).
/// 3. User eats from the container over multiple days
/// 4. User weighs the container again → records finalWeight (e.g. 200g)
/// 5. App calculates: consumed = 500 - 200 = 300g
/// 6. App derives nutrition: (300g / 39g per serving) × nutrients
///
/// The container weight (box/bag) cancels out since both gross measurements include it.
/// A stored tare is optional and adds validation plus initial/remaining-food context.
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
    // Both gross weights include the container itself; it cancels out in the diff.
    var tareWeight: Double? = nil     // Empty container weight in grams, when measured
    var startWeight: Double = 0       // Gross weight at start, including container
    var finalWeight: Double?          // Gross weight when done, nil if still active

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
        tareWeight: Double? = nil,
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
        self.tareWeight = tareWeight
        self.startWeight = startWeight
        self.startDate = startDate
        self.savedFoodID = savedFoodID
    }
}

// MARK: - Computed Properties

extension TrackedContainer {
    /// Returns the end weight from the most recently completed tracking record
    /// for a Food Bank item. This becomes the next tracking record's start weight.
    static func mostRecentEndWeight(
        for savedFoodID: UUID,
        in containers: [TrackedContainer]
    ) -> Double? {
        containers
            .filter { $0.savedFoodID == savedFoodID && $0.finalWeight != nil }
            .max {
                ($0.completedDate ?? $0.startDate) < ($1.completedDate ?? $1.startDate)
            }?
            .finalWeight
    }

    /// Whether this container is still being tracked (no final weight entered yet)
    var isActive: Bool {
        finalWeight == nil
    }

    /// The centralized weight calculation for the persisted measurements.
    var weightCalculation: ContainerWeightCalculation {
        ContainerWeightCalculation(
            tareWeight: tareWeight,
            initialGrossWeight: startWeight,
            endingGrossWeight: finalWeight
        )
    }

    /// Builds a calculation for a candidate completion measurement.
    func weightCalculation(endingAt endingWeight: Double) -> ContainerWeightCalculation {
        ContainerWeightCalculation(
            tareWeight: tareWeight,
            initialGrossWeight: startWeight,
            endingGrossWeight: endingWeight
        )
    }

    /// Food placed in the container at the start. Available only when a tare was recorded.
    var initialFoodGrams: Double? {
        weightCalculation.initialFoodWeight
    }

    /// Food remaining at completion. Available only when a tare and final weight exist.
    var remainingFoodGrams: Double? {
        weightCalculation.remainingFoodWeight
    }

    /// Whether a candidate ending gross weight can safely complete this record.
    func canComplete(at endingWeight: Double) -> Bool {
        weightCalculation(endingAt: endingWeight).isValidCompletion
    }

    /// Total grams of food consumed (start - final). Nil if still active.
    var consumedGrams: Double? {
        weightCalculation.consumedFoodWeight
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
        tareWeight: Double? = nil,
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
            tareWeight: tareWeight,
            startWeight: startWeight,
            savedFoodID: food.id
        )
    }
}

// MARK: - Weight Calculation

/// Provider-independent container-weight math shared by setup, completion, and tests.
///
/// `initialGrossWeight` and `endingGrossWeight` include the physical container.
/// When `tareWeight` is available, the initial and remaining food weights can also
/// be shown without changing the consumption delta used by legacy records.
struct ContainerWeightCalculation: Equatable, Sendable {
    let tareWeight: Double?
    let initialGrossWeight: Double
    let endingGrossWeight: Double?

    var isValidStart: Bool {
        guard initialGrossWeight.isFinite, initialGrossWeight > 0 else { return false }
        guard let tareWeight else { return true }
        return tareWeight.isFinite && tareWeight > 0 && initialGrossWeight > tareWeight
    }

    var isValidCompletion: Bool {
        guard isValidStart,
              let endingGrossWeight,
              endingGrossWeight.isFinite,
              endingGrossWeight >= 0,
              endingGrossWeight < initialGrossWeight else {
            return false
        }
        guard let tareWeight else { return true }
        return endingGrossWeight >= tareWeight
    }

    var initialFoodWeight: Double? {
        guard isValidStart, let tareWeight else { return nil }
        return initialGrossWeight - tareWeight
    }

    var consumedFoodWeight: Double? {
        guard let endingGrossWeight else { return nil }
        // Preserve legacy behavior for already-persisted records whose ending
        // measurement may predate current validation.
        return max(0, initialGrossWeight - endingGrossWeight)
    }

    var remainingFoodWeight: Double? {
        guard let tareWeight, let endingGrossWeight else { return nil }
        return max(0, endingGrossWeight - tareWeight)
    }
}

// MARK: - Weight Entry Actions

/// The two weight-entry methods intentionally produce different outcomes.
///
/// A gross starting weight begins a long-running tracked container. A tare
/// measurement already identifies the food on the scale, so it is a complete
/// journal portion and must not create an active container that requires a
/// second measurement.
enum ContainerWeightAction: Equatable, Sendable {
    case startTracking(initialGrossWeight: Double, gramsPerServing: Double)
    case logTaredFood(TareFoodLogPlan)

    static func enterWeight(
        initialGrossWeight: Double,
        gramsPerServing: Double
    ) -> ContainerWeightAction? {
        guard gramsPerServing.isFinite, gramsPerServing > 0 else { return nil }
        let calculation = ContainerWeightCalculation(
            tareWeight: nil,
            initialGrossWeight: initialGrossWeight,
            endingGrossWeight: nil
        )
        guard calculation.isValidStart else { return nil }
        return .startTracking(
            initialGrossWeight: initialGrossWeight,
            gramsPerServing: gramsPerServing
        )
    }

    static func useTare(
        emptyContainerWeight: Double,
        loadedGrossWeight: Double,
        gramsPerServing: Double
    ) -> ContainerWeightAction? {
        guard gramsPerServing.isFinite, gramsPerServing > 0 else { return nil }
        let calculation = ContainerWeightCalculation(
            tareWeight: emptyContainerWeight,
            initialGrossWeight: loadedGrossWeight,
            endingGrossWeight: nil
        )
        guard calculation.isValidStart,
              let foodWeight = calculation.initialFoodWeight else {
            return nil
        }
        return .logTaredFood(
            TareFoodLogPlan(
                emptyContainerWeight: emptyContainerWeight,
                loadedGrossWeight: loadedGrossWeight,
                foodWeight: foodWeight,
                gramsPerServing: gramsPerServing
            )
        )
    }
}

/// A validated, immediate journal portion produced by an empty-container tare.
struct TareFoodLogPlan: Equatable, Sendable {
    let emptyContainerWeight: Double
    let loadedGrossWeight: Double
    let foodWeight: Double
    let gramsPerServing: Double

    var servings: Double {
        foodWeight / gramsPerServing
    }

    func makeNutritionEntry(
        from food: SavedFood,
        mealType: MealType
    ) -> NutritionEntry {
        let entry = food.toNutritionEntry(mealType: mealType)
        let factor = servings

        entry.calories *= factor
        entry.protein *= factor
        entry.carbs *= factor
        entry.fat *= factor
        entry.micronutrients = entry.micronutrients.mapValues {
            MicronutrientValue(value: $0.value * factor, unit: $0.unit)
        }
        entry.servingCount = factor
        entry.servingQuantity = foodWeight
        entry.servingUnit = "g"
        return entry
    }
}
