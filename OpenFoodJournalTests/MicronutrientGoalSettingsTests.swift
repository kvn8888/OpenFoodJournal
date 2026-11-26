import Foundation
import Testing
@testable import OpenFoodJournal

struct MicronutrientGoalSettingsTests {
    private let vitaminC = KnownMicronutrients.nutrient(forID: "vitamin_c")!
    private let iron = KnownMicronutrients.nutrient(forID: "iron")!

    @Test func decodeTreatsEmptyAndMalformedStorageAsNoOverrides() {
        #expect(MicronutrientGoalSettings.decode("").isEmpty)
        #expect(MicronutrientGoalSettings.decode("   ").isEmpty)
        #expect(MicronutrientGoalSettings.decode("not json").isEmpty)
        #expect(MicronutrientGoalSettings.decode("[1,2]").isEmpty)
    }

    @Test func normalizedDropsTargetsTheUICouldNotRender() {
        let cleaned = MicronutrientGoalSettings.normalized([
            "vitamin_c": 120,
            "  ": 50,
            "iron": 0,
            "zinc": -5,
            "folate": .nan,
            "calcium": .infinity
        ])
        #expect(cleaned == ["vitamin_c": 120])
    }

    @Test func jsonRoundTripPreservesValidTargets() {
        let encoded = MicronutrientGoalSettings.encode(["vitamin_c": 120, "iron": 8, "zinc": 0])
        let decoded = MicronutrientGoalSettings.decode(encoded)
        #expect(decoded == ["vitamin_c": 120, "iron": 8])
        #expect(MicronutrientGoalSettings.encode([:]) == "{}")
    }

    @Test func dailyValueFallsBackToTheFDANumber() {
        #expect(MicronutrientGoalSettings.dailyValue(for: vitaminC, overrides: [:]) == vitaminC.dailyValue)
        #expect(MicronutrientGoalSettings.dailyValue(for: vitaminC, overrides: ["iron": 8]) == vitaminC.dailyValue)
        #expect(MicronutrientGoalSettings.dailyValue(for: vitaminC, overrides: ["vitamin_c": 120]) == 120)
        // A stored zero must never win, or the nutrient reads as untrackable.
        #expect(MicronutrientGoalSettings.dailyValue(for: vitaminC, overrides: ["vitamin_c": 0]) == vitaminC.dailyValue)
        #expect(!MicronutrientGoalSettings.isOverridden(vitaminC, overrides: ["vitamin_c": 0]))
        #expect(MicronutrientGoalSettings.isOverridden(vitaminC, overrides: ["vitamin_c": 120]))
    }

    @Test func userDefaultsRoundTripsOverrides() throws {
        let suite = "MicronutrientGoalSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(MicronutrientGoalSettings.overrides(in: defaults).isEmpty)
        MicronutrientGoalSettings.write(["vitamin_c": 120, "iron": 8], to: defaults)
        #expect(MicronutrientGoalSettings.overrides(in: defaults) == ["vitamin_c": 120, "iron": 8])
    }

    @Test func knownMetricUsesTheOverriddenTarget() {
        #expect(NutritionMetric.known(iron).goal == iron.dailyValue)
        #expect(NutritionMetric.known(iron, overrides: ["iron": 27]).goal == 27)
        // Identity and unit must not drift when the target does.
        let overridden = NutritionMetric.known(iron, overrides: ["iron": 27])
        #expect(overridden.id == iron.id)
        #expect(overridden.unit == iron.unit)
    }

    @MainActor
    @Test func goalsWriteThroughAndClearBackToTheFDAValue() throws {
        let suite = "MicronutrientGoalSettingsTests-goals-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let goals = UserGoals(defaults: defaults)
        #expect(goals.dailyValue(for: vitaminC) == vitaminC.dailyValue)

        goals.setDailyValue(120, for: vitaminC)
        #expect(goals.dailyValue(for: vitaminC) == 120)
        #expect(goals.isOverridden(vitaminC))
        #expect(MicronutrientGoalSettings.overrides(in: defaults) == ["vitamin_c": 120])

        // A fresh instance must see what the previous one persisted.
        #expect(UserGoals(defaults: defaults).dailyValue(for: vitaminC) == 120)

        goals.setDailyValue(nil, for: vitaminC)
        #expect(goals.dailyValue(for: vitaminC) == vitaminC.dailyValue)
        #expect(MicronutrientGoalSettings.overrides(in: defaults).isEmpty)

        goals.setDailyValue(27, for: iron)
        goals.resetAllMicronutrientGoals()
        #expect(goals.micronutrientOverrides.isEmpty)
        #expect(MicronutrientGoalSettings.overrides(in: defaults).isEmpty)
    }

    @MainActor
    @Test func rejectedInputLeavesTheFDAValueInPlace() throws {
        let suite = "MicronutrientGoalSettingsTests-input-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let goals = UserGoals(defaults: defaults)
        for rejected: Double? in [nil, 0, -1, .nan, .infinity] {
            goals.setDailyValue(rejected, for: iron)
            #expect(goals.dailyValue(for: iron) == iron.dailyValue)
            #expect(!goals.isOverridden(iron))
        }
    }

    @Test func appSettingsRecordRoundTripsOverridesAndOlderBackupsStayEmpty() throws {
        let old = try JSONDecoder().decode(
            AppSettingsRecord.self,
            from: Data(#"{"useProModel":false,"offContributeEnabled":false}"#.utf8)
        )
        #expect(old.micronutrientGoalOverrides.isEmpty)

        let settings = AppSettingsRecord(
            useProModel: false,
            micronutrientGoalOverrides: ["vitamin_c": 120, "iron": 0],
            offContributeEnabled: false
        )
        let decoded = try JSONDecoder().decode(AppSettingsRecord.self, from: JSONEncoder().encode(settings))
        #expect(decoded.micronutrientGoalOverrides == ["vitamin_c": 120])
    }
}
