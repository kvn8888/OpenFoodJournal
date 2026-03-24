// OpenFoodJournal — ServingConverter
// Centralises serving-unit conversion logic used by EditEntryView and LogFoodSheet.
// Given a food's baseline macros, serving info, and mappings, this struct can:
//   1. List all available units the user can pick from
//   2. Convert between any two units (factorFor)
//   3. Scale macros for a given quantity + unit combo
// AGPL-3.0 License

import Foundation

/// Pure-value helper that encapsulates all serving-unit math.
/// Both EditEntryView (NutritionEntry) and LogFoodSheet (SavedFood) create one
/// and delegate conversion/scaling to it, eliminating ~80 lines of duplicated logic.
struct ServingConverter {
    // ── Baseline snapshot (set once at init, never mutated) ────────

    /// The food's stored macros at baseline quantity/unit
    let baseCalories: Double
    let baseProtein: Double
    let baseCarbs: Double
    let baseFat: Double

    /// The food's stored serving quantity (e.g. 1.0) — floored to 0.01 to avoid /0
    let baseQuantity: Double

    /// The food's stored serving unit (e.g. "cup", "serving")
    let baseUnit: String

    /// Structured serving info (optional — provides standard conversion tables)
    let serving: ServingSize?

    /// Custom per-food unit mappings (e.g. "1 cup = 244 g")
    let mappings: [ServingMapping]

    // MARK: - Init

    /// Creates a converter from raw values.
    /// `baseQuantity` is clamped to a minimum of 0.01 to prevent division by zero.
    init(
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        quantity: Double,
        unit: String,
        serving: ServingSize?,
        mappings: [ServingMapping]
    ) {
        self.baseCalories = calories
        self.baseProtein = protein
        self.baseCarbs = carbs
        self.baseFat = fat
        self.baseQuantity = max(quantity, 0.01)
        self.baseUnit = unit
        self.serving = serving
        self.mappings = mappings
    }

    // MARK: - Available units

    /// All unique units the user can pick from.
    /// Prefers the structured ServingSize enum (standardised unit tables) when available,
    /// then supplements with any custom units found in servingMappings.
    var availableUnits: [String] {
        if let serving {
            var units = Set(serving.availableUnits)
            units.insert(baseUnit)
            for mapping in mappings {
                units.insert(mapping.from.unit)
                units.insert(mapping.to.unit)
            }
            return units.sorted()
        }
        // Legacy path: derive units entirely from the stored mappings
        var units = Set<String>()
        units.insert(baseUnit)
        for mapping in mappings {
            units.insert(mapping.from.unit)
            units.insert(mapping.to.unit)
        }
        return units.sorted()
    }

    // MARK: - Unit conversion

    /// How many of `unit` equal 1 baseUnit.
    /// e.g. if baseUnit is "cup" and unit is "g", and the serving says 1 cup = 244 g,
    /// then factorFor("g") = 244.0. Falls back to 1.0 if no conversion path exists.
    ///
    /// Tries four strategies in order:
    /// 1. ServingSize standard tables (same-dimension or cross-dimension with density)
    /// 2. Direct servingMapping lookup (baseUnit ↔ target)
    /// 3. Chain: servingMapping (baseUnit → bridge) then standard table (bridge → target)
    /// 4. Canonical SI bridge from serving.grams or serving.ml
    func factorFor(_ unit: String) -> Double {
        if unit == baseUnit { return 1.0 }

        // 1. Try the structured ServingSize enum (same-dimension or cross-dimension)
        if let factor = serving?.convert(1.0, from: baseUnit, to: unit) {
            return factor
        }

        // 2. Direct servingMapping: baseUnit ↔ target
        //    "serving" in a mapping is an alias for baseUnit
        if let factor = mappingFactor(from: baseUnit, to: unit) {
            return factor
        }

        // 3. Chain: servingMapping (baseUnit → bridgeUnit) + standard table (bridge → target)
        for mapping in mappings {
            let pairs: [(from: ServingAmount, to: ServingAmount)] = [
                (mapping.from, mapping.to),
                (mapping.to, mapping.from)
            ]
            for pair in pairs where isBaseUnit(pair.from.unit) {
                let bridgePerBase = pair.to.value / pair.from.value
                if let f = sameDimensionFactor(from: pair.to.unit, to: unit) {
                    return bridgePerBase * f
                }
            }
        }

        // 4. Canonical SI bridge from serving.grams or serving.ml
        if let serving {
            let gramsPerBase = (serving.grams ?? 0) / baseQuantity
            let mlPerBase = (serving.ml ?? 0) / baseQuantity
            if gramsPerBase > 0, let targetPerGram = ServingSize.massConversions[unit] {
                return gramsPerBase / targetPerGram
            }
            if mlPerBase > 0, let targetPerMl = ServingSize.volumeConversions[unit] {
                return mlPerBase / targetPerMl
            }
        }

        return 1.0
    }

    // MARK: - Scaled macros

    /// Returns scaled macros for a given quantity and unit.
    /// Formula: (macros per base-unit) / factorFor(unit) * quantity
    func scaledCalories(quantity: Double, unit: String) -> Double {
        (baseCalories / baseQuantity) / factorFor(unit) * quantity
    }

    func scaledProtein(quantity: Double, unit: String) -> Double {
        (baseProtein / baseQuantity) / factorFor(unit) * quantity
    }

    func scaledCarbs(quantity: Double, unit: String) -> Double {
        (baseCarbs / baseQuantity) / factorFor(unit) * quantity
    }

    func scaledFat(quantity: Double, unit: String) -> Double {
        (baseFat / baseQuantity) / factorFor(unit) * quantity
    }

    // MARK: - Private helpers

    /// Whether the given unit string refers to the food's base serving unit.
    /// "serving" in a mapping is always an alias for baseUnit.
    private func isBaseUnit(_ unit: String) -> Bool {
        unit == baseUnit || unit.lowercased() == "serving"
    }

    /// Direct lookup in servingMappings for a from → to pair (checks both directions).
    /// Treats "serving" as an alias for baseUnit.
    private func mappingFactor(from fromUnit: String, to toUnit: String) -> Double? {
        if fromUnit == toUnit { return 1.0 }
        for mapping in mappings {
            if isBaseUnit(mapping.from.unit) && isBaseUnit(fromUnit)
                && mapping.to.unit == toUnit {
                return mapping.to.value / mapping.from.value
            }
            if isBaseUnit(mapping.to.unit) && isBaseUnit(fromUnit)
                && mapping.from.unit == toUnit {
                return mapping.from.value / mapping.to.value
            }
            // Non-base units: exact match only
            if mapping.from.unit == fromUnit && mapping.to.unit == toUnit {
                return mapping.to.value / mapping.from.value
            }
            if mapping.to.unit == fromUnit && mapping.from.unit == toUnit {
                return mapping.from.value / mapping.to.value
            }
        }
        return nil
    }

    /// Same-dimension factor between two standard units (mass→mass or volume→volume).
    /// Returns nil if the units are in different dimensions or unrecognised.
    private func sameDimensionFactor(from: String, to: String) -> Double? {
        if from == to { return 1.0 }
        if let a = ServingSize.massConversions[from],
           let b = ServingSize.massConversions[to] {
            return a / b
        }
        if let a = ServingSize.volumeConversions[from],
           let b = ServingSize.volumeConversions[to] {
            return a / b
        }
        return nil
    }
}
