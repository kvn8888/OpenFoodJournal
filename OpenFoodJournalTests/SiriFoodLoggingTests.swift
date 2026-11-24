// AGPL-3.0 License

import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

@MainActor
struct SiriFoodLoggingTests {
    @Test
    func resolvesAndScalesFoodBankPortions() throws {
        let fixture = try Fixture()
        let cashews = fixture.addFood("Cashews")
        let pie = fixture.addFood("Pumpkin Pie", brand: "Cóstco")
        let request = try fixture.service.resolve("300 grams of cashews for dinner today")
        guard case .exact(let match) = try fixture.service.search(request.name) else {
            Issue.record("Expected one Food Bank match")
            return
        }
        #expect(match.id == cashews.id)
        let draft = try fixture.service.foodBankDraft(for: match.id, request: request)
        #expect(draft.quantity == 300)
        #expect(draft.unit == "g")
        #expect(draft.calories == 750)
        #expect(draft.protein == 30)
        #expect(draft.carbs == 60)
        #expect(draft.fat == 45)
        #expect(draft.micronutrients["Sodium"] == MicronutrientValue(value: 300, unit: "mg"))
        #expect(try fixture.entries().isEmpty)
        let id = try fixture.service.commit(draft, invocationID: UUID())
        let entry = try #require(fixture.entries().first)
        #expect(entry.id == id)
        #expect(entry.mealType == .dinner)
        #expect(entry.savedFoodID == cashews.id)
        #expect(entry.dailyLog?.date == fixture.calendar.startOfDay(for: fixture.now))
        #expect(entry.timestamp == fixture.now)

        for text in ["108 grams of pumpkin pie from Costco", "108g Costco Pumpkin Pie"] {
            let request = try fixture.service.resolve(text)
            guard case .exact(let match) = try fixture.service.search(request.name) else {
                Issue.record("Expected the branded pie to match")
                continue
            }
            let draft = try fixture.service.foodBankDraft(for: match.id, request: request)
            #expect(match.id == pie.id)
            #expect(draft.calories == 270)
        }
    }

    @Test
    func parsesSpokenPortionMealAndDate() {
        let pie = SiriSpokenFoodQuery("108 grams of pumpkin pie from Costco")
        #expect(pie.name == "pumpkin pie from Costco")
        #expect(pie.quantity == 108)
        #expect(pie.unit == "g")
        #expect(pie.meal == nil)

        let cashews = SiriSpokenFoodQuery("Log 300g cashews for dinner today")
        #expect(cashews.name == "cashews")
        #expect(cashews.quantity == 300)
        #expect(cashews.unit == "g")
        #expect(cashews.meal == .dinner)
        #expect(cashews.dayOffset == 0)

        let tea = SiriSpokenFoodQuery("2.5 fluid ounces of tea yesterday for a snack")
        #expect(tea.name == "tea")
        #expect(tea.quantity == 2.5)
        #expect(tea.unit == "fl oz")
        #expect(tea.meal == .snack)
        #expect(tea.dayOffset == -1)
    }

    @Test
    func disambiguatesActiveFoodBankItemsByRecency() throws {
        let fixture = try Fixture()
        let older = fixture.addFood("Raw Cashews", brand: "Farm")
        older.lastUsedAt = fixture.now.addingTimeInterval(-60)
        let newer = fixture.addFood("Roasted Cashews", brand: "Store")
        let archived = fixture.addFood("Cashews")
        archived.archiveForFoodBank(now: fixture.now)
        let autoArchived = fixture.addFood("Salted Cashews")
        autoArchived.lastUsedAt = fixture.now.addingTimeInterval(-30 * 86_400)

        guard case .ambiguous(let candidates) = try fixture.service.search("cashews") else {
            Issue.record("Expected two active candidates")
            return
        }
        #expect(candidates.map(\.id) == [newer.id, older.id])
        #expect(try fixture.service.activeFoods(ids: [archived.id, newer.id, autoArchived.id]).map(\.id) == [newer.id])
        #expect(try fixture.entries().isEmpty)
    }

    @Test
    func calculatorRequiresIngredientSelection() throws {
        let fixture = try Fixture()
        let calculator = fixture.addFood("Cereal Bowl", kind: .calculator)
        let request = try fixture.service.resolve("100 grams of cereal bowl")
        #expect(throws: SiriFoodLoggingError.calculatorRequiresIngredients) {
            try fixture.service.foodBankDraft(for: calculator.id, request: request)
        }
        #expect(try fixture.entries().isEmpty)
    }

    @Test
    func defaultsUnitAndOffersAlternativesForUnsupportedUnit() throws {
        let fixture = try Fixture()
        let food = fixture.addFood("Cashews")
        let defaultUnit = try fixture.service.resolve("Cashews", quantity: 100)
        let draft = try fixture.service.foodBankDraft(for: food.id, request: defaultUnit)
        #expect(draft.unit == "g")
        #expect(draft.calories == 250)

        let unsupported = try fixture.service.resolve("Cashews", quantity: 2, unit: "cups")
        #expect(throws: SiriFoodLoggingError.unsupportedUnit(
            requested: "cups", availableUnits: ["g", "kg", "lb", "oz"]
        )) {
            try fixture.service.foodBankDraft(for: food.id, request: unsupported)
        }
        let correction = try fixture.service.foodBankDraft(for: food.id, request: unsupported, unitOverride: "ounces")
        #expect(correction.unit == "oz")
        #expect(try fixture.entries().isEmpty)
    }

    @Test
    func normalizesLegacyCustomUnitsAndCanonicalVolumeUnits() throws {
        let fixture = try Fixture()
        let bread = SavedFood(name: "Bread", createdAt: fixture.now, calories: 90, protein: 3, carbs: 15, fat: 2, servingQuantity: 1, servingUnit: "Slice")
        fixture.context.insert(bread)
        let request = try fixture.service.resolve("2 slices of bread")
        let draft = try fixture.service.foodBankDraft(for: bread.id, request: request)
        #expect(draft.calories == 180)
        #expect(draft.unit == "Slice")
        #expect(SiriFoodUnits.normalized("milliliters") == "mL")
        #expect(SiriFoodUnits.normalized("liters") == "L")
        #expect(SiriFoodUnits.matches("Boxes", "box"))
    }

    @Test(arguments: [0, -1, Double.infinity, Double.nan])
    func rejectsInvalidQuantity(quantity: Double) throws {
        let fixture = try Fixture()
        #expect(throws: SiriFoodLoggingError.invalidQuantity) {
            try fixture.service.resolve("Cashews", quantity: quantity)
        }
    }

    @Test
    func assistantMissProducesDraftAndCommitIsRetrySafe() async throws {
        let fixture = try Fixture { request, quantity, unit in
            #expect(request.name == "tahini")
            #expect(quantity == 2)
            #expect(unit == "tbsp")
            return try Self.estimate()
        }
        let request = try fixture.service.resolve("2 tablespoons of tahini for lunch")
        guard case .notFound = try fixture.service.search(request.name),
              case .estimate(let draft) = try await fixture.service.assistantDraft(for: request) else {
            Issue.record("Expected Assistant draft for a Food Bank miss")
            return
        }
        #expect(draft.isAssistantEstimate)
        #expect(draft.sourceSummary == "Nutrition label")
        #expect(draft.calories == 180)
        #expect(try fixture.entries().isEmpty)

        let invocationID = UUID()
        let entryID = try fixture.service.commit(draft, invocationID: invocationID)
        let retryID = try fixture.makeService().commit(draft, invocationID: invocationID)
        #expect(entryID == retryID)
        #expect(try fixture.entries().count == 1)
        let entry = try #require(fixture.entries().first)
        #expect(entry.scanMode == .manual)
        #expect(entry.servingQuantity == 2)
        #expect(entry.servingUnit == "tbsp")
        #expect(entry.mealType == .lunch)
        #expect(entry.savedFoodID == nil)
        #expect(entry.calories == 180)

        let secondID = try fixture.service.commit(draft, invocationID: UUID())
        #expect(entryID != secondID)
        #expect(try fixture.entries().count == 2)
    }

    @Test
    func cancelledConfirmationMakesNoWrite() async throws {
        let fixture = try Fixture { _, _, _ in try Self.estimate() }
        let request = try fixture.service.resolve("2 tablespoons of tahini")
        guard case .estimate(let draft) = try await fixture.service.assistantDraft(for: request) else {
            Issue.record("Expected an estimate")
            return
        }
        let cancelledCommit = Task { @MainActor in
            try fixture.service.commit(draft, invocationID: UUID())
        }
        cancelledCommit.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledCommit.value }
        #expect(try fixture.entries().isEmpty)
    }

    @Test
    func assistantFailuresHandOffTheWholeRequestWithoutWriting() async throws {
        let failures: [any Error] = [
            ChatError.noAPIKey("Gemini"),
            ChatError.serverError(503, "Unavailable"),
            SiriAssistantNutritionLookup.LookupError.invalidEstimate
        ]
        for failure in failures {
            let fixture = try Fixture { _, _, _ in throw failure }
            try await assertHandoff(fixture)
        }
    }

    @Test
    func assistantDeadlineHandsOffWithoutWriting() async throws {
        let fixture = try Fixture { _, _, _ in
            try await SiriAssistantNutritionLookup().withDeadline(.zero) {
                try await Task.sleep(for: .seconds(60))
                return try Self.estimate()
            }
        }
        try await assertHandoff(fixture)
    }

    @Test
    func strictEstimateJSONRejectsInvalidNutrition() throws {
        let estimate = try Self.estimate()
        #expect(estimate.calories == 180)
        #expect(estimate.sourceSummary == "Nutrition label")
        let ungrounded = try SiriAssistantNutritionLookup.decodeEstimate(Self.estimateJSON, hasResearch: false)
        #expect(ungrounded.sourceSummary == nil)
        #expect(throws: SiriAssistantNutritionLookup.LookupError.self) {
            try SiriAssistantNutritionLookup.decodeEstimate(
                Self.estimateJSON.replacingOccurrences(of: "180", with: "-180"), hasResearch: true
            )
        }
        #expect(throws: DecodingError.self) {
            try SiriAssistantNutritionLookup.decodeEstimate("```json\n\(Self.estimateJSON)\n```", hasResearch: true)
        }
    }

    @Test
    func localDateIsFrozenAcrossMidnight() throws {
        let fixture = try Fixture()
        let food = fixture.addFood("Cashews")
        fixture.now = try #require(fixture.calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23, minute: 59)))
        let priorDay = try fixture.service.resolve("Cashews")
        fixture.now.addTimeInterval(120)
        let nextDay = try fixture.service.resolve("Cashews")
        let yesterday = try fixture.service.resolve("Cashews yesterday")
        #expect(fixture.calendar.component(.day, from: priorDay.date) == 23)
        #expect(fixture.calendar.component(.day, from: nextDay.date) == 24)
        #expect(yesterday.date == priorDay.date)
        #expect(nextDay.meal == MealTimeSettings().mealType(for: fixture.now, calendar: fixture.calendar))
        let draft = try fixture.service.foodBankDraft(for: food.id, request: priorDay)
        _ = try fixture.service.commit(draft, invocationID: UUID())
        let entry = try #require(fixture.entries().first)
        #expect(entry.dailyLog?.date == priorDay.date)
        #expect(entry.timestamp == priorDay.requestedAt)
    }

    @Test
    func deviceLockBlocksReadsAndCommitEvenAfterPreview() async throws {
        let fixture = try Fixture { _, _, _ in
            Issue.record("Assistant must not run while locked")
            return try Self.estimate()
        }
        let food = fixture.addFood("Cashews")
        let request = try fixture.service.resolve("100 grams of cashews")
        let draft = try fixture.service.foodBankDraft(for: food.id, request: request)
        fixture.isUnlocked = false
        #expect(throws: SiriFoodLoggingError.deviceLocked) { try fixture.service.search("cashews") }
        #expect(throws: SiriFoodLoggingError.deviceLocked) { try fixture.service.activeFoods(ids: [food.id]) }
        await #expect(throws: SiriFoodLoggingError.deviceLocked) { try await fixture.service.assistantDraft(for: request) }
        #expect(throws: SiriFoodLoggingError.deviceLocked) { try fixture.service.commit(draft, invocationID: UUID()) }
        #expect(try fixture.entries().isEmpty)
        fixture.isUnlocked = true
        _ = try fixture.service.commit(draft, invocationID: UUID())
        #expect(try fixture.entries().count == 1)
    }

    @Test
    func routerDeliversRepeatedPromptsAsSeparateHandoffs() throws {
        let router = AppNavigationRouter()
        #expect(router.takeAssistantPrompt() == nil)
        router.openAssistant(with: "Log a bowl of soup")
        let first = try #require(router.pendingAssistantHandoff)
        #expect(router.takeAssistantPrompt() == first.prompt)
        #expect(router.pendingAssistantHandoff == nil)
        router.openAssistant(with: first.prompt)
        #expect(router.pendingAssistantHandoff?.id != first.id)
        #expect(router.takeAssistantPrompt() == first.prompt)
        #expect(router.takeAssistantPrompt() == nil)
    }

    private func assertHandoff(_ fixture: Fixture) async throws {
        let request = try fixture.service.resolve("2 tbsp tahini for lunch yesterday")
        guard case .needsAppHandoff(let prompt, let reason) = try await fixture.service.assistantDraft(for: request) else {
            Issue.record("Expected foreground handoff")
            return
        }
        #expect(prompt.contains("2 tbsp of tahini for lunch"))
        #expect(prompt.contains(fixture.service.formattedDate(request.date)))
        #expect(!reason.isEmpty)
        #expect(try fixture.entries().isEmpty)
    }

    private static let estimateJSON = """
        {"name":"Tahini","brand":null,"calories":180,"protein":5,"carbs":6,"fat":16,
        "serving_description":"2 tbsp","source_summary":"Nutrition label","confidence":0.8}
        """

    private static func estimate() throws -> SiriAssistantNutritionLookup.Estimate {
        try SiriAssistantNutritionLookup.decodeEstimate(estimateJSON, hasResearch: true)
    }

    @MainActor
    private final class Fixture {
        let container: ModelContainer
        let store: NutritionStore
        let calendar: Calendar
        let assistant: SiriFoodLoggingService.AssistantLookup
        var now: Date
        var isUnlocked = true
        var context: ModelContext { container.mainContext }
        lazy var service = makeService()

        init(assistant: @escaping SiriFoodLoggingService.AssistantLookup = { _, _, _ in
            throw ChatError.noAPIKey("Test")
        }) throws {
            container = try ModelContainer(
                for: NutritionEntry.self, DailyLog.self, SavedFood.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            )
            store = NutritionStore(modelContext: container.mainContext)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
            self.calendar = calendar
            now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 19)))
            self.assistant = assistant
        }

        func makeService() -> SiriFoodLoggingService {
            SiriFoodLoggingService(
                modelContext: context, nutritionStore: store, mealTimeSettings: MealTimeSettings(),
                now: { [unowned self] in now }, calendar: calendar,
                isProtectedDataAvailable: { [unowned self] in isUnlocked }, assistantLookup: assistant
            )
        }

        func addFood(_ name: String, brand: String? = nil, kind: SavedFoodKind = .single) -> SavedFood {
            let food = SavedFood(
                name: name, brand: brand, createdAt: now, calories: 250, protein: 10, carbs: 20, fat: 15,
                micronutrients: ["Sodium": MicronutrientValue(value: 100, unit: "mg")],
                serving: .mass(grams: 100), servingQuantity: 100, servingUnit: "g", kind: kind
            )
            context.insert(food)
            return food
        }

        func entries() throws -> [NutritionEntry] {
            try context.fetch(FetchDescriptor<NutritionEntry>())
        }
    }
}
