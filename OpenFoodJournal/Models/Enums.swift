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
    case barcode = "Barcode"
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

// MARK: - ServingSize

/// A structured serving size that encodes the measurement dimension (mass, volume, or both).
/// Replaces the old free-form `servingSize: String?` with canonical numeric values.
///
/// **Design rationale:**
/// - `.mass(grams:)` — Weight-based serving (e.g. "170g" from a nutrition label).
///   All mass is stored in grams, the universal base unit. Conversions to oz, kg, etc.
///   are just math (no per-food mapping needed).
/// - `.volume(ml:)` — Volume-based serving (e.g. "240 mL" for a beverage).
///   All volume is stored in milliliters. Conversions to cups, tbsp, etc. are standard.
/// - `.both(grams:ml:)` — Has both mass and volume (e.g. "1 cup (228g) = 240ml").
///   Common for foods with known density — enables weight⟷volume conversion.
///
/// Gemini fills this based on label data or food estimation. The app uses it to:
/// 1. Populate the unit picker with dimension-appropriate units
/// 2. Scale macros when the user changes quantity
/// 3. Convert between units within the same dimension (or across dimensions for `.both`)
enum ServingSize: Codable, Hashable, Sendable {
    /// Weight-only serving — stored in grams
    case mass(grams: Double)
    /// Volume-only serving — stored in milliliters
    case volume(ml: Double)
    /// Both weight and volume — enables cross-dimension conversion
    case both(grams: Double, ml: Double)

    // MARK: - Canonical accessors

    /// Weight in grams, if available
    var grams: Double? {
        switch self {
        case .mass(let g): g
        case .both(let g, _): g
        case .volume: nil
        }
    }

    /// Volume in milliliters, if available
    var ml: Double? {
        switch self {
        case .volume(let ml): ml
        case .both(_, let ml): ml
        case .mass: nil
        }
    }

    /// The dimension type as a string — useful for storage and Gemini parsing
    var type: String {
        switch self {
        case .mass: "mass"
        case .volume: "volume"
        case .both: "both"
        }
    }

    /// Human-readable display label (e.g. "170g", "240 mL", "228g / 240 mL")
    var displayString: String {
        switch self {
        case .mass(let g):
            return "\(Self.formatNumber(g))g"
        case .volume(let ml):
            return "\(Self.formatNumber(ml)) mL"
        case .both(let g, let ml):
            return "\(Self.formatNumber(g))g / \(Self.formatNumber(ml)) mL"
        }
    }

    // MARK: - Unit conversion helpers

    /// All display units appropriate for this serving type.
    /// Mass types get weight units, volume types get volume units, both gets all.
    var availableUnits: [String] {
        switch self {
        case .mass: Self.massUnits
        case .volume: Self.volumeUnits
        case .both: Self.massUnits + Self.volumeUnits
        }
    }

    /// Convert a value from one unit to another within the same dimension.
    /// For `.both`, cross-dimension conversion uses the stored grams/mL ratio.
    /// Returns nil if conversion is impossible (e.g. g → mL without density).
    func convert(_ value: Double, from fromUnit: String, to toUnit: String) -> Double? {
        if fromUnit == toUnit { return value }

        // Same-dimension conversions
        if let fromGrams = Self.massConversions[fromUnit],
           let toGrams = Self.massConversions[toUnit] {
            return value * fromGrams / toGrams
        }
        if let fromMl = Self.volumeConversions[fromUnit],
           let toMl = Self.volumeConversions[toUnit] {
            return value * fromMl / toMl
        }

        // Cross-dimension: needs .both
        guard case .both(let g, let ml) = self else { return nil }
        let density = g / ml  // grams per mL

        // Volume → Mass
        if let fromMl = Self.volumeConversions[fromUnit],
           let toGrams = Self.massConversions[toUnit] {
            let inMl = value * fromMl
            let inGrams = inMl * density
            return inGrams / toGrams
        }
        // Mass → Volume
        if let fromGrams = Self.massConversions[fromUnit],
           let toMl = Self.volumeConversions[toUnit] {
            let inGrams = value * fromGrams
            let inMl = inGrams / density
            return inMl / toMl
        }
        return nil
    }

    // MARK: - Standard unit tables

    /// Mass units → grams conversion factors
    static let massUnits = ["g", "oz", "kg", "lb"]
    static let massConversions: [String: Double] = [
        "g": 1.0,
        "oz": 28.3495,
        "kg": 1000.0,
        "lb": 453.592
    ]

    /// Volume units → mL conversion factors
    static let volumeUnits = ["mL", "cup", "tbsp", "tsp", "fl oz", "L"]
    static let volumeConversions: [String: Double] = [
        "mL": 1.0,
        "cup": 236.588,
        "tbsp": 14.787,
        "tsp": 4.929,
        "fl oz": 29.574,
        "L": 1000.0
    ]

    // MARK: - Formatting helper

    private static func formatNumber(_ n: Double) -> String {
        n.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", n)
            : String(format: "%.1f", n)
    }
}
