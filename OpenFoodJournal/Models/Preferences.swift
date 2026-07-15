// Macros — Food Journaling App
// AGPL-3.0 License
//
// Preferences — SwiftData model for persisting user customization choices.
// Singleton pattern: exactly one row exists in the store. Use
// Preferences.current(in:) to get-or-create it.

import SwiftData
import Foundation

enum ShelfRecommendationStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case balanced
    case proteinFocus
    case fiberFocus
    case lowSodium
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: "Balanced"
        case .proteinFocus: "Protein Focus"
        case .fiberFocus: "Fiber Focus"
        case .lowSodium: "Low Sodium"
        case .custom: "Custom"
        }
    }
}

enum ShelfEnergyIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case cut
    case maintain
    case bulk
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cut: "Cut"
        case .maintain: "Maintain"
        case .bulk: "Bulk"
        case .custom: "Custom"
        }
    }

    var detail: String {
        switch self {
        case .cut: "Favor useful nutrition with fewer added calories."
        case .maintain: "Stay near your daily energy target."
        case .bulk: "Prioritize reaching your energy target."
        case .custom: "Choose how calories should influence suggestions."
        }
    }
}

enum ShelfNutritionEmphasis: String, Codable, CaseIterable, Identifiable, Sendable {
    case balanced
    case proteinFocus
    case fiberFocus
    case lowSodium
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: "Balanced"
        case .proteinFocus: "Protein Focus"
        case .fiberFocus: "Fiber Focus"
        case .lowSodium: "Low Sodium"
        case .custom: "Custom"
        }
    }
}

enum ShelfNutrientPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case reach
    case stayNear
    case tryToAvoid
    case ignore

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reach: "Reach"
        case .stayNear: "Stay Near"
        case .tryToAvoid: "Try to Avoid"
        case .ignore: "Ignore"
        }
    }
}

enum ShelfPolicyStrength: String, Codable, CaseIterable, Identifiable, Sendable {
    case gentle
    case standard
    case strong

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var multiplier: Double {
        switch self {
        case .gentle: 0.65
        case .standard: 1
        case .strong: 1.65
        }
    }
}

enum ShelfCalorieFlexibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case strict
    case stayClose
    case flexible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .strict: "Stay under goal"
        case .stayClose: "Stay close to goal"
        case .flexible: "Allow some flexibility"
        }
    }

    func tolerance(for calorieGoal: Double) -> Double {
        switch self {
        case .strict: 0
        case .stayClose: max(50, calorieGoal * 0.025)
        case .flexible: max(100, calorieGoal * 0.05)
        }
    }
}

enum ShelfIncompleteNutritionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case includeCautiously
    case exclude

    var id: String { rawValue }

    var label: String {
        switch self {
        case .includeCautiously: "Include cautiously"
        case .exclude: "Exclude incomplete foods"
        }
    }
}

enum ShelfNutrientRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case prioritize
    case neutral
    case limit

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ShelfNutrient: String, CaseIterable, Identifiable, Sendable {
    case calories
    case protein
    case fiber
    case carbs
    case fat
    case sodium

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calories: "Calories"
        case .protein: "Protein"
        case .fiber: "Fiber"
        case .carbs: "Carbohydrates"
        case .fat: "Fat"
        case .sodium: "Sodium"
        }
    }

    static var nutritionCases: [ShelfNutrient] {
        [.protein, .fiber, .carbs, .fat, .sodium]
    }
}

@Model
final class Preferences {
    // ── Summary Bar Ring Slots ────────────────────────────────────
    // Each slot stores a nutrient ID string:
    //   - Macros: "macro_protein", "macro_carbs", "macro_fat", "macro_calories"
    //   - Micros: any KnownMicronutrient ID like "sodium", "fiber"
    //   - Empty string = unassigned (shows + button)
    var ringSlot1: String = "macro_protein"
    var ringSlot2: String = "macro_carbs"
    var ringSlot3: String = "macro_fat"
    var ringSlot4: String = ""
    var ringSlot5: String = ""

    // Shelf recommendations are synced because Preferences is a CloudKit-backed
    // singleton. Raw values keep SwiftData migration additive and resilient.
    var shelfRecommendationsEnabled: Bool = true
    var shelfSuggestionCount: Int = 3
    var shelfRecommendationStyleRawValue: String = ShelfRecommendationStyle.balanced.rawValue
    var shelfTriggerFraction: Double = 0.5
    var shelfCalorieFlexibilityRawValue: String = ShelfCalorieFlexibility.stayClose.rawValue
    var shelfIncompleteNutritionPolicyRawValue: String = ShelfIncompleteNutritionPolicy.includeCautiously.rawValue

    // The intent/policy model supersedes the original combined style and
    // calorie-flexibility fields below. Legacy fields stay stored so backups
    // and any local pre-release data continue to decode cleanly.
    var shelfEnergyIntentRawValue: String = ShelfEnergyIntent.maintain.rawValue
    var shelfNutritionEmphasisRawValue: String = ""
    var shelfUseRollingWeekContext: Bool = true
    var shelfHardCapCalories: Bool = false
    var shelfHardCapSodium: Bool = false
    var shelfCustomCaloriesPolicyRawValue: String = ShelfNutrientPolicy.stayNear.rawValue
    var shelfCustomProteinPolicyRawValue: String = ShelfNutrientPolicy.reach.rawValue
    var shelfCustomFiberPolicyRawValue: String = ShelfNutrientPolicy.reach.rawValue
    var shelfCustomCarbsPolicyRawValue: String = ShelfNutrientPolicy.ignore.rawValue
    var shelfCustomFatPolicyRawValue: String = ShelfNutrientPolicy.ignore.rawValue
    var shelfCustomSodiumPolicyRawValue: String = ShelfNutrientPolicy.tryToAvoid.rawValue
    var shelfCustomCaloriesStrengthRawValue: String = ShelfPolicyStrength.standard.rawValue
    var shelfCustomProteinStrengthRawValue: String = ShelfPolicyStrength.standard.rawValue
    var shelfCustomFiberStrengthRawValue: String = ShelfPolicyStrength.standard.rawValue
    var shelfCustomCarbsStrengthRawValue: String = ShelfPolicyStrength.gentle.rawValue
    var shelfCustomFatStrengthRawValue: String = ShelfPolicyStrength.gentle.rawValue
    var shelfCustomSodiumStrengthRawValue: String = ShelfPolicyStrength.standard.rawValue

    // Legacy custom-role values are retained for backward-compatible JSON and
    // SwiftData migration. New writes keep them loosely synchronized.
    var shelfCustomCaloriesRoleRawValue: String = ShelfNutrientRole.prioritize.rawValue
    var shelfCustomProteinRoleRawValue: String = ShelfNutrientRole.prioritize.rawValue
    var shelfCustomFiberRoleRawValue: String = ShelfNutrientRole.prioritize.rawValue
    var shelfCustomCarbsRoleRawValue: String = ShelfNutrientRole.neutral.rawValue
    var shelfCustomFatRoleRawValue: String = ShelfNutrientRole.neutral.rawValue
    var shelfCustomSodiumRoleRawValue: String = ShelfNutrientRole.limit.rawValue

    // ── Timestamps ────────────────────────────────────────────────
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}

    var shelfRecommendationStyle: ShelfRecommendationStyle {
        get { ShelfRecommendationStyle(rawValue: shelfRecommendationStyleRawValue) ?? .balanced }
        set { shelfRecommendationStyleRawValue = newValue.rawValue }
    }

    var shelfEnergyIntent: ShelfEnergyIntent {
        get { ShelfEnergyIntent(rawValue: shelfEnergyIntentRawValue) ?? .maintain }
        set { shelfEnergyIntentRawValue = newValue.rawValue }
    }

    var shelfNutritionEmphasis: ShelfNutritionEmphasis {
        get {
            if let emphasis = ShelfNutritionEmphasis(rawValue: shelfNutritionEmphasisRawValue) {
                return emphasis
            }
            return ShelfNutritionEmphasis(rawValue: shelfRecommendationStyleRawValue) ?? .balanced
        }
        set {
            shelfNutritionEmphasisRawValue = newValue.rawValue
            shelfRecommendationStyleRawValue = newValue.rawValue
        }
    }

    var shelfCalorieFlexibility: ShelfCalorieFlexibility {
        get { ShelfCalorieFlexibility(rawValue: shelfCalorieFlexibilityRawValue) ?? .stayClose }
        set { shelfCalorieFlexibilityRawValue = newValue.rawValue }
    }

    var shelfIncompleteNutritionPolicy: ShelfIncompleteNutritionPolicy {
        get { ShelfIncompleteNutritionPolicy(rawValue: shelfIncompleteNutritionPolicyRawValue) ?? .includeCautiously }
        set { shelfIncompleteNutritionPolicyRawValue = newValue.rawValue }
    }

    var clampedShelfSuggestionCount: Int { min(max(shelfSuggestionCount, 1), 5) }

    func shelfRole(for nutrient: ShelfNutrient) -> ShelfNutrientRole {
        let rawValue = switch nutrient {
        case .calories: shelfCustomCaloriesRoleRawValue
        case .protein: shelfCustomProteinRoleRawValue
        case .fiber: shelfCustomFiberRoleRawValue
        case .carbs: shelfCustomCarbsRoleRawValue
        case .fat: shelfCustomFatRoleRawValue
        case .sodium: shelfCustomSodiumRoleRawValue
        }
        return ShelfNutrientRole(rawValue: rawValue) ?? .neutral
    }

    func setShelfRole(_ role: ShelfNutrientRole, for nutrient: ShelfNutrient) {
        switch nutrient {
        case .calories: shelfCustomCaloriesRoleRawValue = role.rawValue
        case .protein: shelfCustomProteinRoleRawValue = role.rawValue
        case .fiber: shelfCustomFiberRoleRawValue = role.rawValue
        case .carbs: shelfCustomCarbsRoleRawValue = role.rawValue
        case .fat: shelfCustomFatRoleRawValue = role.rawValue
        case .sodium: shelfCustomSodiumRoleRawValue = role.rawValue
        }
        updatedAt = .now
    }

    func shelfPolicy(for nutrient: ShelfNutrient) -> ShelfNutrientPolicy {
        let rawValue = switch nutrient {
        case .calories: shelfCustomCaloriesPolicyRawValue
        case .protein: shelfCustomProteinPolicyRawValue
        case .fiber: shelfCustomFiberPolicyRawValue
        case .carbs: shelfCustomCarbsPolicyRawValue
        case .fat: shelfCustomFatPolicyRawValue
        case .sodium: shelfCustomSodiumPolicyRawValue
        }
        if let policy = ShelfNutrientPolicy(rawValue: rawValue) { return policy }
        return switch shelfRole(for: nutrient) {
        case .prioritize: .reach
        case .neutral: .ignore
        case .limit: .tryToAvoid
        }
    }

    func setShelfPolicy(_ policy: ShelfNutrientPolicy, for nutrient: ShelfNutrient) {
        switch nutrient {
        case .calories: shelfCustomCaloriesPolicyRawValue = policy.rawValue
        case .protein: shelfCustomProteinPolicyRawValue = policy.rawValue
        case .fiber: shelfCustomFiberPolicyRawValue = policy.rawValue
        case .carbs: shelfCustomCarbsPolicyRawValue = policy.rawValue
        case .fat: shelfCustomFatPolicyRawValue = policy.rawValue
        case .sodium: shelfCustomSodiumPolicyRawValue = policy.rawValue
        }
        let legacyRole: ShelfNutrientRole = switch policy {
        case .reach: .prioritize
        case .stayNear, .ignore: .neutral
        case .tryToAvoid: .limit
        }
        setShelfRole(legacyRole, for: nutrient)
    }

    func shelfStrength(for nutrient: ShelfNutrient) -> ShelfPolicyStrength {
        let rawValue = switch nutrient {
        case .calories: shelfCustomCaloriesStrengthRawValue
        case .protein: shelfCustomProteinStrengthRawValue
        case .fiber: shelfCustomFiberStrengthRawValue
        case .carbs: shelfCustomCarbsStrengthRawValue
        case .fat: shelfCustomFatStrengthRawValue
        case .sodium: shelfCustomSodiumStrengthRawValue
        }
        return ShelfPolicyStrength(rawValue: rawValue) ?? .standard
    }

    func setShelfStrength(_ strength: ShelfPolicyStrength, for nutrient: ShelfNutrient) {
        switch nutrient {
        case .calories: shelfCustomCaloriesStrengthRawValue = strength.rawValue
        case .protein: shelfCustomProteinStrengthRawValue = strength.rawValue
        case .fiber: shelfCustomFiberStrengthRawValue = strength.rawValue
        case .carbs: shelfCustomCarbsStrengthRawValue = strength.rawValue
        case .fat: shelfCustomFatStrengthRawValue = strength.rawValue
        case .sodium: shelfCustomSodiumStrengthRawValue = strength.rawValue
        }
        updatedAt = .now
    }

    // MARK: - Singleton Access

    /// Fetches the single Preferences row, creating one with defaults if none exists.
    @MainActor
    static func current(in context: ModelContext) -> Preferences {
        let descriptor = FetchDescriptor<Preferences>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let prefs = Preferences()
        context.insert(prefs)
        return prefs
    }
}
