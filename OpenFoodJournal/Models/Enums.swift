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
