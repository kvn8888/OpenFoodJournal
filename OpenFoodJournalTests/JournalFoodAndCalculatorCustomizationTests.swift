import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

@MainActor
struct JournalFoodAndCalculatorCustomizationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: DailyLog.self, NutritionEntry.self, SavedFood.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func calculator() -> SavedFood {
        SavedFood(
            name: "Test Restaurant", calories: 0, protein: 0, carbs: 0, fat: 0,
            kind: .calculator,
            calculatorIngredients: [CalculatorIngredient(name: "Rice", portions: [
                CalculatorPortionOption(label: "Normal", calories: 200, protein: 4, carbs: 40, fat: 2,
                    micronutrients: ["sodium": MicronutrientValue(value: 90, unit: "mg")])
            ])]
        )
    }

    private func selection(_ calculator: SavedFood, quantity: Double = 1) -> CalculatorSelection {
        CalculatorSelection(
            ingredientID: calculator.calculatorIngredients[0].id,
            portionID: calculator.calculatorIngredients[0].portions[0].id,
            quantity: quantity
        )
    }

    @Test func journalSnapshotPreservesNutritionMappingsAndOriginalProvenance() throws {
        let container = try container()
        let context = container.mainContext
        let store = NutritionStore(modelContext: context)
        let queue = SnapshotImageQueue()
        store.configureFoodImageGenerationQueue(queue)
        let sourceID = UUID()
        let entry = NutritionEntry(
            name: "Logged portion", calories: 400, protein: 20, carbs: 40, fat: 10,
            micronutrients: ["calcium": MicronutrientValue(value: 300, unit: "mg")],
            servingSize: "2 servings", brand: "Fixture", serving: .mass(grams: 100),
            servingQuantity: 2, servingUnit: "serving",
            servingMappings: [ServingMapping(from: ServingAmount(value: 1, unit: "serving"), to: ServingAmount(value: 100, unit: "g"))],
            savedFoodID: sourceID
        )
        store.log(entry, to: .now)
        let dayID = entry.dailyLog?.id
        let timestamp = entry.timestamp
        guard case .saved(let food) = store.saveJournalEntryToFoodBank(entry) else {
            Issue.record("Expected saved journal snapshot")
            return
        }
        #expect(food.sourceJournalEntryID == entry.id)
        #expect(food.calories == 400)
        #expect(food.micronutrients == entry.micronutrients)
        #expect(food.servingMappings == entry.servingMappings)
        #expect(food.servingQuantity == 2)
        #expect(entry.savedFoodID == sourceID)
        #expect(entry.dailyLog?.id == dayID)
        #expect(entry.timestamp == timestamp)
        #expect(queue.ids == [food.id])
        let converter = ServingConverter(calories: food.calories, protein: food.protein, carbs: food.carbs, fat: food.fat,
            quantity: food.servingQuantity ?? 1, unit: food.servingUnit ?? "serving", serving: food.serving, mappings: food.servingMappings)
        #expect(converter.scaledCalories(quantity: 200, unit: "g") == 400)

        guard case .alreadySaved(let existing) = store.saveJournalEntryToFoodBank(entry) else {
            Issue.record("Repeated save must return the existing food")
            return
        }
        #expect(existing.id == food.id)
        #expect(try context.fetch(FetchDescriptor<SavedFood>()).count == 1)
        #expect(queue.ids.count == 1)
    }

    @Test func customizationsPersistWithoutCreatingJournalEntries() throws {
        let container = try container()
        let context = container.mainContext
        let store = NutritionStore(modelContext: context)
        let calculator = calculator()
        context.insert(calculator)
        #expect(store.saveCalculatorCustomization(for: calculator, name: "Usual bowl", selections: [selection(calculator, quantity: 2)]))
        #expect(try context.fetch(FetchDescriptor<NutritionEntry>()).isEmpty)
        let reloaded = try #require(ModelContext(container).fetch(FetchDescriptor<SavedFood>()).first)
        let preset = try #require(reloaded.calculatorCustomizations.first)
        #expect(preset.name == "Usual bowl")
        #expect(preset.selections.first?.quantity == 2)
        #expect(preset.canUse(in: reloaded.calculatorIngredients))
    }

    @Test func repeatedCombinationsIgnoreTransientSelectionIDs() throws {
        let calculator = calculator()
        #expect(calculator.rememberCalculatorCustomization(name: "Bowl", selections: [selection(calculator)]))
        let id = try #require(calculator.calculatorCustomizations.first?.id)
        #expect(calculator.rememberCalculatorCustomization(name: "Bowl", selections: [selection(calculator)]))
        #expect(calculator.calculatorCustomizations.count == 1)
        #expect(calculator.calculatorCustomizations.first?.id == id)
        #expect(calculator.rememberCalculatorCustomization(name: "Bowl", selections: [selection(calculator, quantity: 2)]))
        #expect(calculator.calculatorCustomizations.count == 2)
    }

    @Test func loggingRemembersChoicesButLaterNutritionEditsDoNotRewriteHistory() throws {
        let container = try container()
        let context = container.mainContext
        let store = NutritionStore(modelContext: context)
        let calculator = calculator()
        context.insert(calculator)
        let choices = [selection(calculator, quantity: 2)]
        #expect(store.logCalculatorBuild(from: calculator, name: "Bowl", selections: choices, mealType: .lunch, to: .now))
        let logged = try #require(context.fetch(FetchDescriptor<NutritionEntry>()).first)
        #expect(logged.calories == 400)
        #expect(logged.micronutrients["sodium"]?.value == 180)
        #expect(logged.savedFoodID == calculator.id)
        #expect(calculator.calculatorCustomizations.count == 1)
        calculator.calculatorIngredients[0].portions[0].calories = 250
        #expect(SavedFood.calculatorTotals(for: calculator.calculatorIngredients, selections: choices).calories == 500)
        #expect(logged.calories == 400)
    }

    @Test func missingIngredientsAndInvalidAmountsCannotBeReusedOrLogged() throws {
        let container = try container()
        let context = container.mainContext
        let store = NutritionStore(modelContext: context)
        let calculator = calculator()
        context.insert(calculator)
        let choices = [selection(calculator)]
        #expect(calculator.rememberCalculatorCustomization(name: "Bowl", selections: choices))
        let preset = try #require(calculator.calculatorCustomizations.first)
        #expect(!CalculatorCustomization.canUse([selection(calculator, quantity: .nan)], in: calculator.calculatorIngredients))
        #expect(!CalculatorCustomization.canUse([selection(calculator, quantity: 0)], in: calculator.calculatorIngredients))
        #expect(!CalculatorCustomization.canUse([choices[0], choices[0]], in: calculator.calculatorIngredients))
        calculator.calculatorIngredients = []
        #expect(!preset.canUse(in: calculator.calculatorIngredients))
        #expect(!store.logCalculatorBuild(from: calculator, name: "Bowl", selections: choices, mealType: .lunch, to: .now))
        #expect(try context.fetch(FetchDescriptor<NutritionEntry>()).isEmpty)
    }

    @Test func deletionOnlyAffectsTheSelectedCalculatorCustomization() throws {
        let container = try container()
        let context = container.mainContext
        let store = NutritionStore(modelContext: context)
        let first = calculator()
        let second = calculator()
        context.insert(first)
        context.insert(second)
        #expect(store.saveCalculatorCustomization(for: first, name: "First", selections: [selection(first)]))
        #expect(store.saveCalculatorCustomization(for: second, name: "Second", selections: [selection(second)]))
        #expect(store.deleteCalculatorCustomization(try #require(first.calculatorCustomizations.first?.id), from: first))
        #expect(first.calculatorCustomizations.isEmpty)
        #expect(second.calculatorCustomizations.count == 1)
    }

    @Test func backupRoundTripAndLegacyDefaultsPreserveNewFields() throws {
        let calculator = calculator()
        calculator.sourceJournalEntryID = UUID()
        #expect(calculator.rememberCalculatorCustomization(name: "Bowl", selections: [selection(calculator)]))
        let record = SavedFoodRecord(calculator)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SavedFoodRecord.self, from: data)
        let restored = decoded.makeModel()
        #expect(restored.calculatorCustomizations == calculator.calculatorCustomizations)
        #expect(restored.sourceJournalEntryID == calculator.sourceJournalEntryID)
        let updateTarget = self.calculator()
        decoded.apply(to: updateTarget)
        #expect(updateTarget.calculatorCustomizations == calculator.calculatorCustomizations)

        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "calculatorCustomizations")
        legacy.removeValue(forKey: "sourceJournalEntryID")
        let old = try JSONDecoder().decode(SavedFoodRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.calculatorCustomizations.isEmpty)
        #expect(old.sourceJournalEntryID == nil)
    }

    @Test func mirrorSchemaIncludesBothAdditiveFields() throws {
        let table = try #require(TursoSchema.tables.first { $0.name == "ofj_saved_foods" })
        #expect(table.columns.contains { $0.name == "calculator_customizations_json" && $0.type == "TEXT" })
        #expect(table.columns.contains { $0.name == "source_journal_entry_id" && $0.type == "TEXT" })
    }
}

@MainActor
private final class SnapshotImageQueue: SavedFoodImageGenerationQueuing {
    var ids: [UUID] = []
    func enqueueFoodIconImageGeneration(for foodID: UUID) { ids.append(foodID) }
}
