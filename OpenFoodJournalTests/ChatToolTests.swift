// OpenFoodJournal — Every Assistant tool exercised through the shared proxy

import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

@MainActor
struct ChatToolTests {
    private static let expectedTools: Set<String> = [
        "get_daily_summary", "query_entries", "search_food_bank", "get_goals",
        "get_active_energy", "list_calculators", "get_calculator", "web_search",
        "fetch_url", "log_entry", "update_entry", "delete_entry", "save_food",
        "log_saved_food", "update_food",
        "update_goals", "create_calculator", "update_calculator", "read_conversation_source",
        "get_nutrition_context",
    ]

    @Test func registryContainsExactlyTheCoveredProviderNeutralTools() {
        let specs = ChatToolRegistry.all
        #expect(specs.count == 20)
        #expect(Set(specs.map(\.name)) == Self.expectedTools)
        #expect(Set(specs.map(\.name)).count == specs.count)
        #expect(specs.allSatisfy { !$0.description.isEmpty })
        #expect(specs.allSatisfy { !ChatToolRegistry.icon(for: $0.name).isEmpty })
        #expect(Set(specs.filter(\.isWrite).map(\.name)) == [
            "log_entry", "update_entry", "delete_entry", "save_food",
            "log_saved_food", "update_food",
            "update_goals", "create_calculator", "update_calculator",
        ])
    }

    @Test func getDailySummaryReadsEntriesTotalsGoalsAndRemaining() async throws {
        let harness = try ChatTestHarness()
        let date = try #require(Self.day("2026-07-20"))
        let oats = Self.entry(name: "Oats", meal: .breakfast, calories: 310, protein: 12)
        oats.micronutrients = ["iron": MicronutrientValue(value: 4.2, unit: "mg")]
        harness.nutritionStore.log(oats, to: date)

        let record = try #require(await harness.runTool(
            "get_daily_summary",
            args: .object(["date": .string("2026-07-20")])
        ))
        let result = try #require(Self.result(record))
        let totals = try #require(result["totals"]?.objectValue)
        let remaining = try #require(result["remaining"]?.objectValue)
        let entries = try #require(result["entries"]?.arrayValue)

        #expect(record.status == .completed)
        #expect(totals["calories"]?.doubleValue == 310)
        #expect(totals["protein"]?.doubleValue == 12)
        #expect(remaining["calories"]?.doubleValue == 1_690)
        #expect(entries.first?["name"]?.stringValue == "Oats")
        #expect(entries.first?["micronutrients"]?["iron"]?["value"]?.doubleValue == 4.2)
    }

    @Test func queryEntriesFiltersAcrossDateRangeAndMeal() async throws {
        let harness = try ChatTestHarness()
        let first = try #require(Self.day("2026-07-19"))
        let second = try #require(Self.day("2026-07-20"))
        harness.nutritionStore.log(Self.entry(name: "Lunch Bowl", meal: .lunch), to: first)
        let dinner = Self.entry(name: "Dinner Bowl", meal: .dinner)
        dinner.micronutrients = ["sodium": MicronutrientValue(value: 510, unit: "mg")]
        harness.nutritionStore.log(dinner, to: second)

        let record = try #require(await harness.runTool("query_entries", args: .object([
            "start_date": .string("2026-07-19"),
            "end_date": .string("2026-07-20"),
            "meal": .string("Dinner"),
        ])))
        let entries = try #require(Self.result(record)?["entries"]?.arrayValue)

        #expect(entries.count == 1)
        #expect(entries.first?["name"]?.stringValue == "Dinner Bowl")
        #expect(entries.first?["date"]?.stringValue == "2026-07-20")
        #expect(entries.first?["micronutrients"]?["sodium"]?["unit"]?.stringValue == "mg")
    }

    @Test func searchFoodBankFindsNameOrBrand() async throws {
        let harness = try ChatTestHarness()
        let food = SavedFood(
            name: "Greek Yogurt", brand: "Test Dairy", calories: 120,
            protein: 18, carbs: 8, fat: 1,
            micronutrients: [
                "Calcium": MicronutrientValue(value: 220, unit: "mg"),
                "Vitamin B12": MicronutrientValue(value: 1.4, unit: "mcg"),
            ],
            servingSize: "1 cup"
        )
        harness.context.insert(food)

        let record = try #require(await harness.runTool(
            "search_food_bank",
            args: .object(["query": .string("Dairy")])
        ))
        let foods = try #require(Self.result(record)?["foods"]?.arrayValue)

        #expect(foods.count == 1)
        #expect(foods.first?["food_id"]?.stringValue == food.id.uuidString)
        #expect(foods.first?["protein"]?.doubleValue == 18)
        let micronutrients = try #require(foods.first?["micronutrients"]?.objectValue)
        #expect(micronutrients["Calcium"]?["value"]?.doubleValue == 220)
        #expect(micronutrients["Calcium"]?["unit"]?.stringValue == "mg")
        #expect(micronutrients["Vitamin B12"]?["value"]?.doubleValue == 1.4)
        #expect(micronutrients["Vitamin B12"]?["unit"]?.stringValue == "mcg")
    }

    @Test func getGoalsReadsInjectedGoalInterface() async throws {
        let harness = try ChatTestHarness()
        harness.goals.dailyCalories = 2_250
        harness.goals.dailyProtein = 175

        let record = try #require(await harness.runTool("get_goals"))
        let goals = try #require(Self.result(record)?["goals"]?.objectValue)

        #expect(goals["calories"]?.doubleValue == 2_250)
        #expect(goals["protein"]?.doubleValue == 175)
    }

    @Test func getActiveEnergyReadsInjectedHealthInterface() async throws {
        let harness = try ChatTestHarness()
        harness.health.activeEnergy = 517.6

        let record = try #require(await harness.runTool(
            "get_active_energy",
            args: .object(["date": .string("2026-07-20")])
        ))
        let result = try #require(Self.result(record))

        #expect(result["active_energy_kcal"]?.doubleValue == 518)
        #expect(result["date"]?.stringValue == "2026-07-20")
        #expect(harness.health.requestedDates.count == 1)
    }

    @Test func getNutritionContextCombinesGoalsEntriesMicronutrientsAndEnergy() async throws {
        let harness = try ChatTestHarness()
        harness.health.activeEnergy = 605
        let date = try #require(Self.day("2026-07-20"))
        let entry = Self.entry(name: "Fortified Yogurt", meal: .breakfast, calories: 220, protein: 20)
        entry.micronutrients = [
            "calcium": MicronutrientValue(value: 300, unit: "mg"),
            "vitamin_b12": MicronutrientValue(value: 1.2, unit: "mcg"),
        ]
        harness.nutritionStore.log(entry, to: date)

        let record = try #require(await harness.runTool(
            "get_nutrition_context",
            args: .object([
                "date": .string("2026-07-20"),
                "include_active_energy": .bool(true),
            ])
        ))
        let result = try #require(Self.result(record))
        let totals = try #require(result["totals"]?.objectValue)
        let micronutrients = try #require(result["micronutrient_totals"]?.objectValue)
        let energy = try #require(result["active_energy"]?.objectValue)

        #expect(record.status == .completed)
        #expect(totals["calories"]?.doubleValue == 220)
        #expect(energy["kcal"]?.doubleValue == 605)
        #expect(micronutrients["calcium"]?["value"]?.doubleValue == 300)
        #expect(micronutrients["vitamin_b12"]?["unit"]?.stringValue == "mcg")
    }

    @Test func listCalculatorsReturnsOnlyCalculatorFoods() async throws {
        let harness = try ChatTestHarness()
        let calculator = Self.calculator(name: "Sub Shop")
        let normalFood = SavedFood(name: "Apple", calories: 95, protein: 0, carbs: 25, fat: 0)
        harness.context.insert(calculator)
        harness.context.insert(normalFood)

        let record = try #require(await harness.runTool("list_calculators"))
        let calculators = try #require(Self.result(record)?["calculators"]?.arrayValue)

        #expect(calculators.count == 1)
        #expect(calculators.first?["calculator_id"]?.stringValue == calculator.id.uuidString)
        #expect(calculators.first?["ingredient_count"]?.doubleValue == 1)
    }

    @Test func getCalculatorReturnsAllIngredientsAndPortions() async throws {
        let harness = try ChatTestHarness()
        let calculator = Self.calculator(name: "Sub Shop")
        harness.context.insert(calculator)

        let record = try #require(await harness.runTool(
            "get_calculator",
            args: .object(["calculator_id": .string(calculator.id.uuidString)])
        ))
        let ingredients = try #require(Self.result(record)?["ingredients"]?.arrayValue)
        let portions = try #require(ingredients.first?["portions"]?.arrayValue)

        #expect(ingredients.first?["name"]?.stringValue == "Turkey")
        #expect(portions.first?["label"]?.stringValue == "1 scoop")
        #expect(portions.first?["calories"]?.doubleValue == 90)
        #expect(portions.first?["micronutrients"]?["iron"]?["value"]?.doubleValue == 1.5)
    }

    @Test func logEntryRequiresApprovalAndPersistsJournalEntry() async throws {
        let harness = try ChatTestHarness(healthSyncEnabled: true)
        let record = try #require(await harness.runTool("log_entry", args: .object([
            "name": .string("Egg Sandwich"), "brand": .string("Cafe"),
            "calories": .number(420), "protein": .number(24),
            "carbs": .number(38), "fat": .number(18),
            "micronutrients": .array([
                .object(["name": .string("Iron"), "value": .number(3.5), "unit": .string("mg")]),
            ]),
            "meal": .string("Breakfast"), "date": .string("2026-07-20"),
            "serving_description": .string("1 sandwich"),
        ])))
        let entry = try #require(harness.nutritionStore.fetchAllEntries().first)
        await Self.waitUntil { harness.health.syncedEntryIDs.contains(entry.id) }

        #expect(record.status == .completed)
        #expect(entry.name == "Egg Sandwich")
        #expect(entry.brand == "Cafe")
        #expect(entry.mealType == .breakfast)
        #expect(entry.calories == 420)
        #expect(entry.micronutrients["iron"]?.value == 3.5)
        #expect(harness.permissions.requests.last?.title == "Log to Journal")
        #expect(harness.health.syncedEntryIDs == [entry.id])
    }

    @Test func updateEntryChangesOnlyRequestedFields() async throws {
        let harness = try ChatTestHarness(healthSyncEnabled: true)
        let entry = Self.entry(name: "Toast", meal: .breakfast, calories: 100, protein: 3)
        entry.micronutrients = [
            "iron": MicronutrientValue(value: 1, unit: "mg"),
            "sodium": MicronutrientValue(value: 220, unit: "mg"),
        ]
        harness.nutritionStore.log(entry, to: .now)
        await Self.waitUntil { harness.health.syncedEntryIDs.contains(entry.id) }
        harness.health.resetNutritionMutations()

        let record = try #require(await harness.runTool("update_entry", args: .object([
            "entry_id": .string(entry.id.uuidString),
            "name": .string("Toast with Butter"),
            "calories": .number(180),
            "micronutrients": .array([
                .object(["name": .string("Iron"), "value": .number(2), "unit": .string("mg")]),
            ]),
            "remove_micronutrients": .array([.string("Sodium")]),
        ])))
        await Self.waitUntil { harness.health.syncedEntryIDs.contains(entry.id) }

        #expect(record.status == .completed)
        #expect(entry.name == "Toast with Butter")
        #expect(entry.calories == 180)
        #expect(entry.protein == 3)
        #expect(entry.micronutrients["iron"]?.value == 2)
        #expect(entry.micronutrients["sodium"] == nil)
        #expect(harness.health.syncedEntryIDs == [entry.id])
    }

    @Test func deleteEntryRemovesOnlySelectedEntry() async throws {
        let harness = try ChatTestHarness(healthSyncEnabled: true)
        let doomed = Self.entry(name: "Delete Me")
        let retained = Self.entry(name: "Keep Me")
        harness.nutritionStore.log(doomed, to: .now)
        harness.nutritionStore.log(retained, to: .now)
        await Self.waitUntil {
            harness.health.syncedEntryIDs.contains(doomed.id) &&
            harness.health.syncedEntryIDs.contains(retained.id)
        }
        harness.health.resetNutritionMutations()

        let record = try #require(await harness.runTool(
            "delete_entry",
            args: .object(["entry_id": .string(doomed.id.uuidString)])
        ))
        await Self.waitUntil { harness.health.deletedEntryIDs.contains(doomed.id) }

        #expect(record.status == .completed)
        #expect(harness.nutritionStore.fetchAllEntries().map(\.name) == ["Keep Me"])
        #expect(harness.health.deletedEntryIDs == [doomed.id])
    }

    @Test func assistantJournalWriteDoesNotExportWhenAppleHealthIsDisabled() async throws {
        let harness = try ChatTestHarness(healthSyncEnabled: false)
        _ = try #require(await harness.runTool("log_entry", args: .object([
            "name": .string("Local Only"),
            "calories": .number(250),
            "protein": .number(12),
            "carbs": .number(30),
            "fat": .number(9),
            "meal": .string("Snack"),
            "date": .string("2026-07-20"),
        ])))
        await Self.yieldForScheduledMutations()

        #expect(harness.nutritionStore.fetchAllEntries().count == 1)
        #expect(harness.health.syncedEntryIDs.isEmpty)
        #expect(harness.health.deletedEntryIDs.isEmpty)
    }

    @Test func saveFoodPersistsReusableFood() async throws {
        let harness = try ChatTestHarness()
        let record = try #require(await harness.runTool("save_food", args: .object([
            "name": .string("Protein Bowl"), "brand": .string("Kitchen"),
            "calories": .number(510), "protein": .number(42),
            "carbs": .number(55), "fat": .number(14),
            "micronutrients": .array([
                .object([
                    "name": .string("Calcium"),
                    "value": .number(240),
                    "unit": .string("mg"),
                ]),
                .object([
                    "name": .string("Vitamin B12"),
                    "value": .number(1.8),
                    "unit": .string("mcg"),
                ]),
            ]),
            "serving_description": .string("1 bowl"),
        ])))
        let foods = try harness.context.fetch(FetchDescriptor<SavedFood>())
        let food = try #require(foods.first)
        let resultMicronutrients = try #require(Self.result(record)?["micronutrients"]?.objectValue)
        let permissionLines = try #require(harness.permissions.requests.last?.detailLines)

        #expect(record.status == .completed)
        #expect(food.name == "Protein Bowl")
        #expect(food.protein == 42)
        #expect(food.servingSize == "1 bowl")
        #expect(food.micronutrients["calcium"] == MicronutrientValue(value: 240, unit: "mg"))
        #expect(food.micronutrients["vitamin_b12"] == MicronutrientValue(value: 1.8, unit: "mcg"))
        #expect(resultMicronutrients["calcium"]?["value"]?.doubleValue == 240)
        #expect(resultMicronutrients["vitamin_b12"]?["unit"]?.stringValue == "mcg")
        #expect(permissionLines.contains("Calcium → 240 mg"))
        #expect(permissionLines.contains("Vitamin B12 → 1.8 mcg"))
    }

    @Test func updateGoalsMutatesInjectedGoalInterface() async throws {
        let harness = try ChatTestHarness()
        let record = try #require(await harness.runTool("update_goals", args: .object([
            "calories": .number(2_300),
            "protein": .number(180),
        ])))

        #expect(record.status == .completed)
        #expect(harness.goals.dailyCalories == 2_300)
        #expect(harness.goals.dailyProtein == 180)
        #expect(harness.goals.dailyCarbs == 225)
    }

    @Test func logSavedFoodPreservesLinkAndScalesAllNutrition() async throws {
        let harness = try ChatTestHarness(healthSyncEnabled: true)
        let food = SavedFood(
            name: "Fortified Cereal",
            calories: 200,
            protein: 8,
            carbs: 40,
            fat: 2,
            micronutrients: [
                "iron": MicronutrientValue(value: 9, unit: "mg"),
                "vitamin_b12": MicronutrientValue(value: 2.4, unit: "mcg"),
            ],
            servingQuantity: 1,
            servingUnit: "cup"
        )
        harness.context.insert(food)

        let record = try #require(await harness.runTool("log_saved_food", args: .object([
            "food_id": .string(food.id.uuidString),
            "quantity": .number(1.5),
            "unit": .string("cup"),
            "meal": .string("Breakfast"),
            "date": .string("2026-07-20"),
        ])))
        let entry = try #require(harness.nutritionStore.fetchAllEntries().first)
        await Self.waitUntil { harness.health.syncedEntryIDs.contains(entry.id) }

        #expect(record.status == .completed)
        #expect(entry.savedFoodID == food.id)
        #expect(entry.calories == 300)
        #expect(entry.micronutrients["iron"]?.value == 13.5)
        #expect(entry.micronutrients["vitamin_b12"]?.value == 3.6)
        #expect(entry.servingQuantity == 1.5)
        #expect(entry.servingUnit == "cup")
        #expect(harness.health.syncedEntryIDs == [entry.id])
    }

    @Test func updateFoodMergesAndRemovesMicronutrients() async throws {
        let harness = try ChatTestHarness()
        let food = SavedFood(
            name: "Yogurt",
            calories: 120,
            protein: 18,
            carbs: 8,
            fat: 1,
            micronutrients: [
                "calcium": MicronutrientValue(value: 220, unit: "mg"),
                "sodium": MicronutrientValue(value: 80, unit: "mg"),
            ]
        )
        harness.context.insert(food)

        let record = try #require(await harness.runTool("update_food", args: .object([
            "food_id": .string(food.id.uuidString),
            "protein": .number(20),
            "micronutrients": .array([
                .object(["name": .string("Calcium"), "value": .number(260), "unit": .string("mg")]),
                .object(["name": .string("Vitamin B12"), "value": .number(1.4), "unit": .string("mcg")]),
            ]),
            "remove_micronutrients": .array([.string("Sodium")]),
        ])))

        #expect(record.status == .completed)
        #expect(food.protein == 20)
        #expect(food.micronutrients["calcium"]?.value == 260)
        #expect(food.micronutrients["vitamin_b12"]?.unit == "mcg")
        #expect(food.micronutrients["sodium"] == nil)
    }

    @Test func servingConverterScalesMicronutrientsWithMacros() {
        let converter = ServingConverter(
            calories: 100,
            protein: 5,
            carbs: 20,
            fat: 1,
            quantity: 1,
            unit: "serving",
            serving: nil,
            mappings: []
        )
        let scaled = converter.scaledMicronutrients(
            ["iron": MicronutrientValue(value: 2, unit: "mg")],
            quantity: 2.5,
            unit: "serving"
        )

        #expect(converter.scaledCalories(quantity: 2.5, unit: "serving") == 250)
        #expect(scaled["iron"]?.value == 5)
        #expect(scaled["iron"]?.unit == "mg")
    }

    @Test func createCalculatorProducesEditableReviewDraftAndSavedResult() async throws {
        let harness = try ChatTestHarness()
        let savedID = UUID()
        let args = Self.calculatorArgs(name: "Build a Sub")

        let record = try #require(await harness.runTool(
            "create_calculator",
            args: args,
            permission: .calculatorSaved(id: savedID, name: "Build a Sub", ingredientCount: 1)
        ))
        let request = try #require(harness.permissions.requests.last)
        let draft = try #require(request.calculatorDraft)

        #expect(request.title == "Create Nutrition Calculator")
        #expect(draft.existingID == nil)
        #expect(draft.name == "Build a Sub")
        #expect(draft.ingredients.first?.portions.first?.protein == 18)
        #expect(draft.ingredients.first?.portions.first?.micronutrients["iron"]?.value == 1.5)
        #expect(Self.result(record)?["calculator_id"]?.stringValue == savedID.uuidString)
    }

    @Test func updateCalculatorPrefillsExistingCalculatorForReview() async throws {
        let harness = try ChatTestHarness()
        let existing = Self.calculator(name: "Old Name")
        harness.context.insert(existing)
        let savedID = existing.id

        let record = try #require(await harness.runTool(
            "update_calculator",
            args: .object([
                "calculator_id": .string(existing.id.uuidString),
                "name": .string("New Name"),
                "ingredients": Self.calculatorArgs(name: "Unused")["ingredients"] ?? .array([]),
            ]),
            permission: .calculatorSaved(id: savedID, name: "New Name", ingredientCount: 1)
        ))
        let draft = try #require(harness.permissions.requests.last?.calculatorDraft)

        #expect(draft.existingID == existing.id)
        #expect(draft.name == "New Name")
        #expect(draft.ingredients.count == 1)
        #expect(Self.result(record)?["status"]?.stringValue == "saved")
    }

    // web_search and fetch_url have focused coverage in ChatFeatureTests,
    // including the proxy subrequest, HTML extraction, and PDF replay path.

    private static func result(_ record: ChatToolRecord) -> [String: JSONValue]? {
        JSONValue.parse(record.resultJSON)?.objectValue
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
    }

    private static func yieldForScheduledMutations() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private static func day(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    private static func entry(
        name: String,
        meal: MealType = .snack,
        calories: Double = 200,
        protein: Double = 10
    ) -> NutritionEntry {
        NutritionEntry(
            name: name,
            mealType: meal,
            calories: calories,
            protein: protein,
            carbs: 20,
            fat: 8
        )
    }

    private static func calculator(name: String) -> SavedFood {
        SavedFood(
            name: name,
            brand: "Test Restaurant",
            calories: 0,
            protein: 0,
            carbs: 0,
            fat: 0,
            kind: .calculator,
            calculatorIngredients: [
                CalculatorIngredient(
                    name: "Turkey",
                    portions: [CalculatorPortionOption(
                        label: "1 scoop",
                        calories: 90,
                        protein: 18,
                        carbs: 1,
                        fat: 2,
                        micronutrients: [
                            "iron": MicronutrientValue(value: 1.5, unit: "mg"),
                        ]
                    )]
                )
            ]
        )
    }

    private static func calculatorArgs(name: String) -> JSONValue {
        .object([
            "name": .string(name),
            "brand": .string("Test Restaurant"),
            "ingredients": .array([
                .object([
                    "name": .string("Turkey"),
                    "portions": .array([
                        .object([
                            "label": .string("1 scoop"),
                            "calories": .number(90),
                            "protein": .number(18),
                            "carbs": .number(1),
                            "fat": .number(2),
                            "micronutrients": .array([
                                .object(["name": .string("Iron"), "value": .number(1.5), "unit": .string("mg")]),
                            ]),
                        ])
                    ]),
                ])
            ]),
        ])
    }
}
