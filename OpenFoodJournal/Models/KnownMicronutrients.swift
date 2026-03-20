// OpenFoodJournal — KnownMicronutrients
// Comprehensive reference data for all FDA-recognized micronutrients.
// Each nutrient has a canonical name, unit, daily recommended value,
// and a "common" flag (true = shown by default on labels, false = collapsed).
//
// Daily values are based on the FDA 2020 Daily Value Reference (2000 cal diet).
// Sources: 21 CFR 101.9, FDA.gov "Daily Value on the New Nutrition and Supplement Facts Labels"
//
// Gemini can return any nutrient name — if it matches a known nutrient,
// we use the canonical data. If not, it appears as "Other" in the UI.
// AGPL-3.0 License

import Foundation

/// Reference data for a single known micronutrient.
/// This is NOT a SwiftData model — it's static reference data used for:
/// 1. Populating progress bars in the micronutrient summary view
/// 2. Validating/normalizing Gemini scan results
/// 3. Providing daily value targets for each nutrient
struct KnownMicronutrient: Identifiable, Hashable, Sendable {
    let id: String            // Canonical lowercase key (e.g. "vitamin_a")
    let name: String          // Display name (e.g. "Vitamin A")
    let unit: String          // Standard unit (e.g. "mcg", "mg", "g")
    let dailyValue: Double    // FDA recommended daily value
    let isCommon: Bool        // true = always visible; false = collapsed under "More"
    let category: Category    // Grouping for the UI

    /// Categories for visual grouping in the summary view
    enum Category: String, CaseIterable, Sendable {
        case vitamin = "Vitamins"
        case mineral = "Minerals"
        case other = "Other Nutrients"
    }
}

// MARK: - Complete FDA Micronutrient Database

/// Static reference containing all FDA-recognized micronutrients with daily values.
/// Access via `KnownMicronutrients.all` for the full list, or use the lookup helpers.
enum KnownMicronutrients {

    // ── Vitamins ──────────────────────────────────────────────────

    static let vitaminA = KnownMicronutrient(
        id: "vitamin_a", name: "Vitamin A", unit: "mcg",
        dailyValue: 900, isCommon: true, category: .vitamin
    )

    static let vitaminC = KnownMicronutrient(
        id: "vitamin_c", name: "Vitamin C", unit: "mg",
        dailyValue: 90, isCommon: true, category: .vitamin
    )

    static let vitaminD = KnownMicronutrient(
        id: "vitamin_d", name: "Vitamin D", unit: "mcg",
        dailyValue: 20, isCommon: true, category: .vitamin
    )

    static let vitaminE = KnownMicronutrient(
        id: "vitamin_e", name: "Vitamin E", unit: "mg",
        dailyValue: 15, isCommon: false, category: .vitamin
    )

    static let vitaminK = KnownMicronutrient(
        id: "vitamin_k", name: "Vitamin K", unit: "mcg",
        dailyValue: 120, isCommon: false, category: .vitamin
    )

    static let thiamin = KnownMicronutrient(
        id: "thiamin", name: "Thiamin (B1)", unit: "mg",
        dailyValue: 1.2, isCommon: false, category: .vitamin
    )

    static let riboflavin = KnownMicronutrient(
        id: "riboflavin", name: "Riboflavin (B2)", unit: "mg",
        dailyValue: 1.3, isCommon: false, category: .vitamin
    )

    static let niacin = KnownMicronutrient(
        id: "niacin", name: "Niacin (B3)", unit: "mg",
        dailyValue: 16, isCommon: false, category: .vitamin
    )

    static let pantothenicAcid = KnownMicronutrient(
        id: "pantothenic_acid", name: "Pantothenic Acid (B5)", unit: "mg",
        dailyValue: 5, isCommon: false, category: .vitamin
    )

    static let vitaminB6 = KnownMicronutrient(
        id: "vitamin_b6", name: "Vitamin B6", unit: "mg",
        dailyValue: 1.7, isCommon: false, category: .vitamin
    )

    static let biotin = KnownMicronutrient(
        id: "biotin", name: "Biotin (B7)", unit: "mcg",
        dailyValue: 30, isCommon: false, category: .vitamin
    )

    static let folate = KnownMicronutrient(
        id: "folate", name: "Folate (B9)", unit: "mcg",
        dailyValue: 400, isCommon: false, category: .vitamin
    )

    static let vitaminB12 = KnownMicronutrient(
        id: "vitamin_b12", name: "Vitamin B12", unit: "mcg",
        dailyValue: 2.4, isCommon: false, category: .vitamin
    )

    // ── Minerals ──────────────────────────────────────────────────

    static let calcium = KnownMicronutrient(
        id: "calcium", name: "Calcium", unit: "mg",
        dailyValue: 1300, isCommon: true, category: .mineral
    )

    static let iron = KnownMicronutrient(
        id: "iron", name: "Iron", unit: "mg",
        dailyValue: 18, isCommon: true, category: .mineral
    )

    static let magnesium = KnownMicronutrient(
        id: "magnesium", name: "Magnesium", unit: "mg",
        dailyValue: 420, isCommon: false, category: .mineral
    )

    static let phosphorus = KnownMicronutrient(
        id: "phosphorus", name: "Phosphorus", unit: "mg",
        dailyValue: 1250, isCommon: false, category: .mineral
    )

    static let potassium = KnownMicronutrient(
        id: "potassium", name: "Potassium", unit: "mg",
        dailyValue: 4700, isCommon: true, category: .mineral
    )

    static let sodium = KnownMicronutrient(
        id: "sodium", name: "Sodium", unit: "mg",
        dailyValue: 2300, isCommon: true, category: .mineral
    )

    static let zinc = KnownMicronutrient(
        id: "zinc", name: "Zinc", unit: "mg",
        dailyValue: 11, isCommon: false, category: .mineral
    )

    static let copper = KnownMicronutrient(
        id: "copper", name: "Copper", unit: "mg",
        dailyValue: 0.9, isCommon: false, category: .mineral
    )

    static let manganese = KnownMicronutrient(
        id: "manganese", name: "Manganese", unit: "mg",
        dailyValue: 2.3, isCommon: false, category: .mineral
    )

    static let selenium = KnownMicronutrient(
        id: "selenium", name: "Selenium", unit: "mcg",
        dailyValue: 55, isCommon: false, category: .mineral
    )

    static let chromium = KnownMicronutrient(
        id: "chromium", name: "Chromium", unit: "mcg",
        dailyValue: 35, isCommon: false, category: .mineral
    )

    static let molybdenum = KnownMicronutrient(
        id: "molybdenum", name: "Molybdenum", unit: "mcg",
        dailyValue: 45, isCommon: false, category: .mineral
    )

    static let iodine = KnownMicronutrient(
        id: "iodine", name: "Iodine", unit: "mcg",
        dailyValue: 150, isCommon: false, category: .mineral
    )

    static let chloride = KnownMicronutrient(
        id: "chloride", name: "Chloride", unit: "mg",
        dailyValue: 2300, isCommon: false, category: .mineral
    )

    // ── Other Nutrients ───────────────────────────────────────────

    static let fiber = KnownMicronutrient(
        id: "fiber", name: "Dietary Fiber", unit: "g",
        dailyValue: 28, isCommon: true, category: .other
    )

    static let addedSugars = KnownMicronutrient(
        id: "added_sugars", name: "Added Sugars", unit: "g",
        dailyValue: 50, isCommon: true, category: .other
    )

    static let cholesterol = KnownMicronutrient(
        id: "cholesterol", name: "Cholesterol", unit: "mg",
        dailyValue: 300, isCommon: true, category: .other
    )

    static let saturatedFat = KnownMicronutrient(
        id: "saturated_fat", name: "Saturated Fat", unit: "g",
        dailyValue: 20, isCommon: true, category: .other
    )

    static let transFat = KnownMicronutrient(
        id: "trans_fat", name: "Trans Fat", unit: "g",
        dailyValue: 0, isCommon: true, category: .other  // No safe level; DV = 0
    )

    // ── Collection Helpers ────────────────────────────────────────

    /// All known micronutrients in display order (vitamins → minerals → other)
    static let all: [KnownMicronutrient] = [
        // Vitamins
        vitaminA, vitaminC, vitaminD, vitaminE, vitaminK,
        thiamin, riboflavin, niacin, pantothenicAcid,
        vitaminB6, biotin, folate, vitaminB12,
        // Minerals
        calcium, iron, magnesium, phosphorus, potassium, sodium,
        zinc, copper, manganese, selenium, chromium, molybdenum, iodine, chloride,
        // Other
        fiber, addedSugars, cholesterol, saturatedFat, transFat
    ]

    /// Only the nutrients commonly shown on nutrition labels (isCommon == true)
    static let common: [KnownMicronutrient] = all.filter(\.isCommon)

    /// Nutrients not commonly shown on labels (collapsed in UI by default)
    static let uncommon: [KnownMicronutrient] = all.filter { !$0.isCommon }

    /// Fast lookup by canonical ID (e.g. "vitamin_a")
    static let byID: [String: KnownMicronutrient] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    /// Fast lookup by display name (case-insensitive).
    /// Maps lowercase name → KnownMicronutrient for matching Gemini output.
    static let byName: [String: KnownMicronutrient] = {
        var map: [String: KnownMicronutrient] = [:]
        for nutrient in all {
            // Primary name
            map[nutrient.name.lowercased()] = nutrient
            // Also map the ID form (underscores → spaces)
            map[nutrient.id.replacingOccurrences(of: "_", with: " ")] = nutrient
        }
        // Common aliases people and Gemini might use
        map["vitamin b1"] = thiamin
        map["vitamin b2"] = riboflavin
        map["vitamin b3"] = niacin
        map["vitamin b5"] = pantothenicAcid
        map["vitamin b7"] = biotin
        map["vitamin b9"] = folate
        map["folic acid"] = folate
        map["b12"] = vitaminB12
        map["b6"] = vitaminB6
        map["dietary fiber"] = fiber
        map["fibre"] = fiber
        map["sat fat"] = saturatedFat
        map["sat. fat"] = saturatedFat
        return map
    }()

    /// Attempts to find a known micronutrient matching a free-text name from Gemini.
    /// Returns nil if the name doesn't match any known nutrient.
    static func find(_ name: String) -> KnownMicronutrient? {
        // Try exact ID match first
        if let nutrient = byID[name.lowercased()] {
            return nutrient
        }
        // Then try name match
        return byName[name.lowercased()]
    }

    /// Grouped by category for display in the summary view
    static let grouped: [(category: KnownMicronutrient.Category, nutrients: [KnownMicronutrient])] = {
        KnownMicronutrient.Category.allCases.compactMap { category in
            let nutrients = all.filter { $0.category == category }
            return nutrients.isEmpty ? nil : (category, nutrients)
        }
    }()
}
