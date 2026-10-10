// OpenFoodJournal — MicronutrientGoalSettings
// Per-nutrient daily targets that replace the FDA Daily Value.
// AGPL-3.0 License

import Foundation

/// User-set daily targets for micronutrients, keyed by canonical nutrient ID.
///
/// The FDA Daily Values in `KnownMicronutrients` stay the shipped default. An
/// entry here replaces the target for that one nutrient and nothing else, so a
/// person tracking a clinical iron target does not have to restate every other
/// value. Removing an entry restores the FDA number.
///
/// Only positive, finite targets are stored. Clearing a field in Settings drops
/// the override rather than storing zero, because zero already means "no daily
/// value" everywhere else in the app and would read as an untrackable nutrient.
enum MicronutrientGoalSettings {
    static let overridesKey = "goals.micronutrientOverrides"

    static func overrides(in defaults: UserDefaults = .standard) -> [String: Double] {
        decode(defaults.string(forKey: overridesKey) ?? "")
    }

    static func write(_ overrides: [String: Double], to defaults: UserDefaults = .standard) {
        defaults.set(encode(overrides), forKey: overridesKey)
    }

    static func decode(_ raw: String) -> [String: Double] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return normalized(decoded)
    }

    static func encode(_ overrides: [String: Double]) -> String {
        let values = normalized(overrides)
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Drops entries the UI could never render: blank IDs, and targets that are
    /// not a usable positive number.
    static func normalized(_ overrides: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (id, value) in overrides {
            let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, value.isFinite, value > 0 else { continue }
            result[key] = value
        }
        return result
    }

    /// The target to show for a nutrient: the user's, or the FDA default.
    static func dailyValue(for nutrient: KnownMicronutrient, overrides: [String: Double]) -> Double {
        guard let custom = overrides[nutrient.id], custom.isFinite, custom > 0 else {
            return nutrient.dailyValue
        }
        return custom
    }

    static func isOverridden(_ nutrient: KnownMicronutrient, overrides: [String: Double]) -> Bool {
        guard let custom = overrides[nutrient.id] else { return false }
        return custom.isFinite && custom > 0
    }
}
