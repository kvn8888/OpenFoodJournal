import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import OpenFoodJournal

@MainActor
struct NutritionAnalyticsTests {
    private let calories = NutritionMetric(id: "macro:calories", name: "Calories", unit: "kcal", goal: 2500, macro: .calories)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 12))!
    }
    private func log(_ date: Date, calories: Double = 100, micros: [String: MicronutrientValue] = [:]) -> DailyLog {
        let entry = NutritionEntry(name: "Test meal", calories: calories, protein: 10, carbs: 20, fat: 4)
        entry.micronutrients = micros
        let log = DailyLog(date: date)
        log.date = calendar.startOfDay(for: date)
        log.entries = [entry]
        return log
    }

    @Test func preservesEveryDaySlotAcrossDSTAndMissingDays() {
        let logs = [log(date(7)), log(date(9), calories: 300)]
        let snapshot = NutritionAnalytics(logs: logs, calendar: calendar)
        let points = snapshot.series(calories, ending: date(9), days: 3)
        #expect(points.map { calendar.component(.day, from: $0.date) } == [7, 8, 9])
        #expect(points.map(\.value) == [100, nil, 300])
        #expect(points[2].date.timeIntervalSince(points[1].date) == 23 * 3600)
        #expect(NutritionAnalytics.average(points) == 200)
    }

    @Test func zeroCountsButAbsentNutrientDoesNot() {
        let sodium = NutritionMetric.known(KnownMicronutrients.sodium)
        let snapshot = NutritionAnalytics(logs: [
            log(date(7), micros: ["sodium": .init(value: 0, unit: "mg")]),
            log(date(8)),
            log(date(9), micros: ["sodium": .init(value: 100, unit: "mg")])
        ], calendar: calendar)
        let points = snapshot.series(sodium, ending: date(9), days: 3)
        #expect(points.map(\.value) == [0, nil, 100])
        #expect(NutritionAnalytics.average(points) == 50)
    }

    @Test func canonicalAliasAndUnitConversionDoNotDoubleCount() {
        let snapshot = NutritionAnalytics(logs: [log(date(9), micros: [
            "sodium": .init(value: 1, unit: "g"),
            "Sodium": .init(value: 5000, unit: "mg"),
            "Dietary Fiber": .init(value: 2000, unit: "mg")
        ])], calendar: calendar)
        let values = snapshot.valuesByDate[calendar.startOfDay(for: date(9))]!
        #expect(abs(values["sodium"]! - 1000) < 0.001)
        #expect(abs(values["fiber"]! - 2) < 0.001)
        #expect(snapshot.trackedMicros.count == 2)
    }

    @Test func customAndIncompatibleUnitsRemainVisibleWithoutInventedGoals() {
        let snapshot = NutritionAnalytics(logs: [log(date(9), micros: [
            "Vitamin A": .init(value: 100, unit: "IU"),
            "My Nutrient": .init(value: 0, unit: "mg"),
            "vitamin_a": .init(value: 900, unit: "mcg")
        ])], calendar: calendar)
        #expect(snapshot.trackedMicros.count == 3)
        let incompatible = snapshot.trackedMicros.first { $0.unit == "IU" }!
        #expect(incompatible.goal == 0)
        #expect(incompatible.id != "vitamin_a")
        let custom = snapshot.trackedMicros.first { $0.name == "My Nutrient" }!
        #expect(custom.goal == 0)
        #expect(snapshot.series(custom, ending: date(9), days: 1).first?.value == 0)
    }

    @Test func ignoresInvalidNumbersAndRetainsAllTrackedMicrosAlphabetically() {
        let values = Dictionary(uniqueKeysWithValues: KnownMicronutrients.all.map { ($0.id, MicronutrientValue(value: 0, unit: $0.unit)) })
        let day = log(date(9), micros: values)
        day.safeEntries[0].micronutrients["bad"] = .init(value: .infinity, unit: "g")
        let snapshot = NutritionAnalytics(logs: [day], calendar: calendar)
        #expect(snapshot.trackedMicros.count == KnownMicronutrients.all.count)
        #expect(!snapshot.trackedMicros.contains { $0.name == "Bad" })
        #expect(snapshot.trackedMicros.map(\.name) == snapshot.trackedMicros.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func duplicateCloudKitDaysAndEntryRelationshipsDoNotInflateTotals() {
        let populated = log(date(9), calories: 250)
        let empty = DailyLog(date: date(9)); empty.date = populated.date
        let entry = populated.safeEntries[0]
        populated.entries = [entry, entry]
        let snapshot = NutritionAnalytics(logs: [empty, populated], calendar: calendar)
        #expect(snapshot.entries(on: date(9)).count == 1)
        #expect(snapshot.series(calories, ending: date(9), days: 1).first?.value == 250)
    }

    @Test func historicalContributionsMatchSummaryAndExcludeNewerDays() {
        let first = log(date(7), calories: 100)
        let second = log(date(8), calories: 200)
        second.safeEntries[0].name = "Other meal"
        let newer = log(date(9), calories: 9000)
        let snapshot = NutritionAnalytics(logs: [first, second, newer], calendar: calendar)
        let contributions = snapshot.contributions(calories, ending: date(8), days: 2)
        #expect(contributions.count == 2)
        #expect(contributions.reduce(0) { $0 + $1.value } == 150)
        #expect(contributions.reduce(0) { $0 + $1.value } == NutritionAnalytics.average(snapshot.series(calories, ending: date(8), days: 2)))
    }

    @Test func rebuildingSnapshotReflectsEntryEditsAndDeletions() {
        let day = log(date(9), calories: 100)
        let old = NutritionAnalytics(logs: [day], calendar: calendar)
        day.safeEntries[0].calories = 250
        let edited = NutritionAnalytics(logs: [day], calendar: calendar)
        #expect(old.series(calories, ending: date(9), days: 1).first?.value == 100)
        #expect(edited.series(calories, ending: date(9), days: 1).first?.value == 250)
        day.entries = []
        #expect(NutritionAnalytics(logs: [day], calendar: calendar).series(calories, ending: date(9), days: 1).first?.value == nil)
    }

    @Test func periodNavigationClampsAtToday() {
        #expect(NutritionDateRange.count(.daily) == 1)
        #expect(NutritionDateRange.count(.weekly) == 7)
        #expect(NutritionDateRange.count(.monthly) == 30)
        let next = NutritionDateRange.next(date(7), direction: 1, days: 7, today: date(9), calendar: calendar)
        #expect(next == calendar.startOfDay(for: date(9)))
        #expect(calendar.component(.day, from: NutritionDateRange.start(ending: date(9), days: 7, calendar: calendar)) == 3)
    }

    @Test func calendarPaletteAndMacroOverageMatchApprovedDesign() {
        let protein = NutritionMetric(id: "macro:protein", name: "Protein", unit: "g", goal: 100, macro: .protein)
        let env = EnvironmentValues()
        #expect(protein.color(for: 99).resolve(in: env) == Color.blue.resolve(in: env))
        #expect(protein.color(for: 101).resolve(in: env) == OFJColor.calendarOverGoalRGB.color.resolve(in: env))
        for ratio in [0.0, 0.79, 0.80, 0.95, 1.0, 1.05, 1.5] {
            #expect(calories.color(for: ratio * 2500).resolve(in: env) == OFJColor.journalCalorieState(for: ratio).ringColor.resolve(in: env))
        }
    }
}
