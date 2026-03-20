// Macros — Food Journaling App
// AGPL-3.0 License

import Foundation

// MARK: - MealType

enum MealType: String, Codable, CaseIterable, Identifiable {
    case breakfast = "Breakfast"
    case lunch = "Lunch"
    case dinner = "Dinner"
    case snack = "Snack"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon.stars"
        case .snack: "leaf"
        }
    }
}

// MARK: - ScanMode

enum ScanMode: String, Codable, CaseIterable {
    case label = "Label Scan"
    case foodPhoto = "Food Photo"
    case manual = "Manual"

    var isEstimate: Bool {
        self == .foodPhoto
    }
}

// MARK: - MicronutrientValue

/// A single micronutrient measurement with its numeric value and unit.
/// Stored as part of a `[String: MicronutrientValue]` dictionary on NutritionEntry.
/// Gemini auto-fills both the value and the unit (e.g. "g", "mg", "mcg", "%DV").
/// Being Codable, SwiftData serializes the whole dictionary as a JSON blob —
/// no schema migration needed when Gemini starts returning new nutrients.
struct MicronutrientValue: Codable, Hashable, Sendable {
    /// The numeric amount (e.g. 300 for "300 mcg")
    var value: Double
    /// The unit string (e.g. "g", "mg", "mcg", "%DV", "IU")
    var unit: String
}

// MARK: - ServingAmount

/// A structured serving measurement: a numeric quantity paired with a unit.
/// For example: 1 "cup", 220 "g", 3 "cookies", 1 "piece".
/// Used both as the canonical serving size on a food AND as endpoints in ServingMapping.
struct ServingAmount: Codable, Hashable, Sendable {
    /// The numeric amount (e.g. 1.0, 220.0, 3.0)
    var value: Double
    /// The unit label — can be standard ("g", "ml", "cup") or arbitrary ("cookie", "slice")
    var unit: String

    /// Human-readable display string, e.g. "1 cup" or "220 g"
    var displayString: String {
        let formatted = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return "\(formatted) \(unit)"
    }
}

// MARK: - ServingMapping

/// A conversion between two equivalent serving amounts for a specific food.
/// Example: for Whole Milk, { from: 1 "cup", to: 244 "g" }
/// These are stored per-food because density / weight varies between foods.
/// The user measures once (e.g. weighs 1 cup of their milk = 244g) and
/// the app can convert between any mapped units going forward.
struct ServingMapping: Codable, Hashable, Sendable {
    /// The "from" side of the equivalence (e.g. 1 cup)
    var from: ServingAmount
    /// The "to" side of the equivalence (e.g. 244 g)
    var to: ServingAmount
}
