// AGPL-3.0 License

import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

@MainActor
struct SiriJournalDataTests {
    @Test
    func usesSavedVersionsAndScopesSpokenBrandRepliesToMatches() throws {
        let fixture = try Fixture()
        let amazon = try fixture.data.createFood(fixture.portion("Whole Milk", brand: "Amazon Grocery"))
        let kirkland = try fixture.data.createFood(fixture.portion("Whole Milk", brand: "Kirkland"))
        _ = try fixture.data.createFood(fixture.portion("Crackers", brand: "Amazon Grocery"))
        let candidates = try fixture.data.foods(query: "milk", includeArchived: false)
        #expect(Set(candidates.map(\.id)) == [amazon.id, kirkland.id])
        #expect(SiriFoodLoggingService.matchingChoice("It's the Amazon brand", in: candidates).map(\.id) == [amazon.id])
        #expect(SiriFoodLoggingService.matchingChoice("crackers", in: candidates).isEmpty)
        #expect(SiriFoodLoggingService.matchingChoice("milk", in: candidates).count == 2)

        let snapshot = SiriSavedFoodSnapshot(amazon)
        _ = try fixture.data.updateFood(snapshot, values: snapshot.nutrition, archived: true, onShelf: nil)
        #expect(try fixture.data.foods(query: "milk", includeArchived: false).map(\.id) == [kirkland.id])
        #expect(try fixture.data.foods(query: "Amazon milk", includeArchived: true).map(\.id) == [amazon.id])
        let request = try fixture.logging.resolve("half a cup of milk")
        let draft = try fixture.logging.foodBankDraft(for: amazon, request: request)
        #expect(draft.calories == 80.125)
        #expect(throws: SiriFoodLoggingError.savedFoodUnavailable) {
            try fixture.logging.foodBankDraft(for: amazon.id, request: request)
        }
    }

    @Test
    func readsExactDailyAndRangeTotalsAndDividesByCalendarDays() throws {
        let fixture = try Fixture()
        let yesterday = try #require(fixture.data.calendar.date(byAdding: .day, value: -1, to: fixture.today))
        let values = fixture.portion("Milk", micronutrients: ["Sodium": .init(value: 20.25, unit: "mg")])
        _ = try fixture.data.createEntry(values, meal: .breakfast, day: yesterday)
        _ = try fixture.data.createEntry(values, meal: .lunch, day: yesterday)

        let day = try fixture.data.summary(from: yesterday, through: nil, meal: .breakfast)
        #expect(day.entryCount == 1)
        #expect(day.total.calories == 160.25)
        #expect(day.total.micronutrients.first?.value == 20.25)
        #expect(day.remaining == nil)

        let range = try fixture.data.summary(from: yesterday, through: fixture.today, meal: nil)
        #expect(range.days == 2)
        #expect(range.trackedDays == 1)
        #expect(range.total.calories == 320.5)
        #expect(range.dailyAverage.calories == 160.25)
        #expect(range.dailyAverage.micronutrients.first?.unit == "mg")
        #expect(range.dailyAverage.micronutrients.first?.value == 20.25)
        #expect(throws: SiriJournalDataError.invalidRange) {
            try fixture.data.entries(from: fixture.today, through: yesterday)
        }
        #expect(try fixture.data.page(Array(0..<52), number: 3) == [50, 51])
        #expect(throws: SiriJournalDataError.invalidPage) {
            try fixture.data.page([1], number: Int.max)
        }
    }

    @Test
    func editsMovesAndDeletesAnExactEntryAndPreservesItsSavedTemplate() throws {
        let fixture = try Fixture()
        let values = fixture.portion("Milk", micronutrients: ["Sodium": .init(value: 20.0, unit: "mg")])
        let entry = try fixture.data.createEntry(values, meal: .breakfast, day: fixture.today)
        let expected = SiriJournalEntrySnapshot(entry)
        let saved = try fixture.data.saveEntryToFoodBank(expected)
        #expect(try fixture.data.saveEntryToFoodBank(expected).id == saved.id)
        #expect(try fixture.data.hasRecentMatchingEntry(values, meal: .breakfast, day: fixture.today, requestedAt: fixture.today))
        let yesterday = try #require(fixture.data.calendar.date(byAdding: .day, value: -1, to: fixture.today))
        let edit = SiriNutritionEdit(quantity: 0.5)
        let scaled = try edit.apply(to: expected.nutrition, serving: expected.serving, mappings: expected.mappings)
        let moved = try fixture.data.updateEntry(expected, values: scaled, meal: .dinner, day: yesterday)
        #expect(moved.id == expected.id)
        #expect(moved.calories == 80.125)
        #expect(moved.micronutrients["Sodium"]?.value == 10)
        #expect(moved.mealType == .dinner)
        #expect(try fixture.data.entries(from: fixture.today, through: nil).entries.isEmpty)
        #expect(try fixture.data.entries(from: yesterday, through: nil).entries.map(\.id) == [moved.id])
        #expect(throws: SiriJournalDataError.recordChanged) { try fixture.data.deleteEntry(expected) }
        let current = SiriJournalEntrySnapshot(moved)
        try fixture.data.deleteEntry(current)
        try fixture.data.deleteEntry(current)
        #expect(try fixture.data.entry(id: current.id) == nil)
        #expect(saved.calories == 160.25)
    }

    @Test
    func blocksLockedReadsAndProtectsUnfinishedAppEdits() throws {
        let fixture = try Fixture()
        let entry = try fixture.data.createEntry(fixture.portion("Milk"), meal: .breakfast, day: fixture.today)
        let original = SiriJournalEntrySnapshot(entry)
        let food = try fixture.data.createFood(fixture.portion("Apples"))
        let foodID = food.id
        food.name = "Unfinished app edit"

        #expect(throws: SiriJournalDataError.unsavedChanges) { try fixture.data.deleteEntry(original) }
        #expect(food.name == "Unfinished app edit")
        #expect(fixture.context.hasChanges)
        let verifier = ModelContext(fixture.container)
        let persisted = try verifier.fetch(FetchDescriptor<SavedFood>(predicate: #Predicate { $0.id == foodID }))
        #expect(persisted.first?.name == "Apples")

        fixture.isUnlocked = false
        #expect(throws: SiriFoodLoggingError.deviceLocked) { try fixture.data.foods(includeArchived: true) }
        #expect(throws: SiriFoodLoggingError.deviceLocked) { try fixture.data.summary(from: nil, through: nil, meal: nil) }
        #expect(throws: SiriFoodLoggingError.deviceLocked) { try fixture.data.deleteEntry(original) }
    }

    @Test
    func readsEmptyPreferencesWithoutCreatingDataAndDeletesSavedFoodWithoutChangingJournal() throws {
        let fixture = try Fixture()
        _ = try fixture.data.preferences()
        #expect(!fixture.context.hasChanges)
        let entry = try fixture.data.createEntry(fixture.portion("Milk"), meal: .breakfast, day: fixture.today)
        let food = try fixture.data.saveEntryToFoodBank(SiriJournalEntrySnapshot(entry))
        let expected = SiriSavedFoodSnapshot(food)
        try fixture.data.deleteFood(expected)
        try fixture.data.deleteFood(expected)
        #expect(try fixture.data.food(id: expected.id) == nil)
        #expect(try fixture.data.entry(id: entry.id)?.calories == 160.25)
    }

    @MainActor
    private final class Fixture {
        let container: ModelContainer
        let today = Date(timeIntervalSince1970: 1_795_526_800)
        let calendar = Calendar(identifier: .gregorian)
        let goals = UserGoals()
        let times = MealTimeSettings()
        var isUnlocked = true
        var context: ModelContext { container.mainContext }
        lazy var store = NutritionStore(modelContext: context)
        lazy var logging = SiriFoodLoggingService(
            modelContext: context, nutritionStore: store, mealTimeSettings: times,
            now: { [unowned self] in today }, calendar: calendar,
            isProtectedDataAvailable: { [unowned self] in isUnlocked },
            assistantLookup: { _, _, _ in
                Issue.record("Siri read coverage must use the local store.")
                throw SiriFoodLoggingError.missingFood
            }
        )
        lazy var data = SiriJournalData(store: store, goals: goals, mealTimes: times, foodLogging: logging,
                                       calendar: calendar, now: { [unowned self] in today })

        init() throws {
            container = try ModelContainer(for: NutritionEntry.self, DailyLog.self, SavedFood.self, Preferences.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        }

        func portion(_ name: String, brand: String? = nil, micronutrients: [String: MicronutrientValue] = [:]) -> SiriStoredNutrition {
            SiriStoredNutrition(name: name, brand: brand, quantity: 1, unit: "cup", calories: 160.25,
                                protein: 8, carbs: 12, fat: 9, micronutrients: micronutrients)
        }
    }
}
