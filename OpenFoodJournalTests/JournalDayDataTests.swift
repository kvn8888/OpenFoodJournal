// OpenFoodJournal — Journal's shared query/totals contract (no UI automation)

import Foundation
import Observation
import SwiftData
import Testing
@testable import OpenFoodJournal

@MainActor
struct JournalDayDataTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var day: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 30))!
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: DailyLog.self, NutritionEntry.self, SavedFood.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func entry(calories: Double = 400) -> NutritionEntry {
        NutritionEntry(name: "Fixture food", calories: calories, protein: 20, carbs: 40, fat: 12)
    }

    private func totals(
        _ logs: [DailyLog]
    ) -> [Date: JournalDayTotals] {
        JournalDayData.totalsByDate(from: JournalDayData.preferredLogs(from: logs, calendar: calendar))
    }

    @Test("the same query includes the first log inserted into a previously empty day")
    func firstEntryAppearsWithoutChangingDate() throws {
        let container = try container()
        let context = container.mainContext
        let descriptor = JournalDayData.fetchDescriptor(referenceDate: day, calendar: calendar)
        #expect(try context.fetch(descriptor).isEmpty)

        let store = NutritionStore(modelContext: context)
        let food = entry()
        store.log(food, to: day)

        let snapshot = try totals(context.fetch(descriptor))
        let savedDay = try #require(food.dailyLog?.date)
        let values = try #require(snapshot[calendar.startOfDay(for: savedDay)])
        #expect(values.calories == 400)
        #expect(values.protein == 20)
        #expect(values.calorieProgress(goal: 2_000) == 0.2)
    }

    @Test("building the shared snapshot observes existing entry calorie changes")
    func existingEntriesRemainObservable() async throws {
        let container = try container()
        let context = container.mainContext
        let log = DailyLog(date: day)
        let food = entry()
        context.insert(log)
        context.insert(food)
        log.entries = [food]
        food.dailyLog = log
        try context.save()

        await confirmation("totals invalidated after entry edit") { changed in
            withObservationTracking {
                _ = totals([log])
            } onChange: {
                changed()
            }
            food.calories = 650
        }
        #expect(totals([log])[calendar.startOfDay(for: log.date)]?.calories == 650)
    }

    @Test("an observed empty log invalidates when a relationship is populated")
    func lateRelationshipArrivalIsObserved() async throws {
        let container = try container()
        let context = container.mainContext
        let log = DailyLog(date: day)
        context.insert(log)
        try context.save()
        await confirmation("totals invalidated after relationship arrival") { changed in
            withObservationTracking {
                _ = totals([log])
            } onChange: {
                changed()
            }
            log.entries = [entry()]
        }
        #expect(totals([log])[calendar.startOfDay(for: log.date)]?.calories == 400)
    }

    @Test("moving and deleting entries updates both days in the shared totals")
    func moveAndDeleteReconcileDayTotals() throws {
        let container = try container()
        let context = container.mainContext
        let store = NutritionStore(modelContext: context)
        let food = entry()
        store.log(food, to: day)
        let originalDay = try #require(food.dailyLog?.date)
        let destination = try #require(calendar.date(byAdding: .day, value: -1, to: day))
        let descriptor = JournalDayData.fetchDescriptor(referenceDate: day, calendar: calendar)

        store.moveEntry(food, to: destination)
        let destinationDay = try #require(food.dailyLog?.date)
        let moved = try totals(context.fetch(descriptor))
        #expect((moved[calendar.startOfDay(for: originalDay)] ?? .zero).calories == 0)
        #expect(moved[calendar.startOfDay(for: destinationDay)]?.calories == 400)

        store.delete(food)
        let deleted = try totals(context.fetch(descriptor))
        #expect((deleted[calendar.startOfDay(for: destinationDay)] ?? .zero).calories == 0)
    }

    @Test("direct persistence changes do not need NutritionStore's local write counter")
    func querySeesWritesOutsideStore() throws {
        let container = try container()
        let context = container.mainContext
        let store = NutritionStore(modelContext: context)
        let descriptor = JournalDayData.fetchDescriptor(referenceDate: day, calendar: calendar)
        #expect(try context.fetch(descriptor).isEmpty)

        // Represents an import/merge writing directly to SwiftData. Actual
        // CloudKit delivery remains an on-device smoke check, not a mock claim.
        let log = DailyLog(date: day)
        let food = entry(calories: 700)
        context.insert(log)
        context.insert(food)
        food.dailyLog = log
        log.entries = [food]
        try context.save()

        #expect(store.changeCount == 0)
        let snapshot = try totals(context.fetch(descriptor))
        #expect(snapshot[calendar.startOfDay(for: log.date)]?.calories == 700)
    }

    @Test("duplicate CloudKit days follow the populated-row and stable-UUID rule")
    func duplicateDaysAreNotAddedTogether() {
        let first = DailyLog(date: day, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = DailyLog(date: day, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        second.entries = [entry(calories: 300)]
        let key = calendar.startOfDay(for: first.date)
        #expect(totals([first, second])[key]?.calories == 300)

        first.entries = [entry(calories: 500)]
        #expect(totals([second, first])[key]?.calories == 500)
        #expect(totals([first, second])[key]?.calories == 500)
    }

    @Test("calorie-goal changes recompute progress without rewriting journal data")
    func goalChangesAndInvalidGoals() {
        var values = JournalDayTotals.zero
        values.calories = 1_000
        #expect(values.calorieProgress(goal: 2_000) == 0.5)
        #expect(values.calorieProgress(goal: 2_500) == 0.4)
        #expect(values.calorieProgress(goal: 0) == 0)
        #expect(values.calorieProgress(goal: .nan) == 0)
        #expect(values.calorieProgress(goal: 800) == 1.25)
    }

    @Test("the shared snapshot keeps macro and normalized micronutrient totals")
    func macroAndMicronutrientTotals() {
        let first = entry()
        first.micronutrients = ["Calcium": MicronutrientValue(value: 30, unit: "mg")]
        let second = entry(calories: 100)
        second.micronutrients = ["calcium": MicronutrientValue(value: 70, unit: "mg")]
        let values = JournalDayTotals(entries: [first, second])
        #expect(values.calories == 500)
        #expect(values.protein == 40)
        #expect(values.carbs == 80)
        #expect(values.fat == 24)
        #expect(values.micronutrients[KnownMicronutrients.normalize("calcium")] == 100)
    }
}
