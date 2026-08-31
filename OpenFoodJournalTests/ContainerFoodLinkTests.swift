import Foundation
import Testing
import UIKit
@testable import OpenFoodJournal

@MainActor
struct ContainerFoodLinkTests {
    private func food() -> SavedFood {
        let food = SavedFood(name: "Cashews", calories: 160, protein: 5, carbs: 9, fat: 13)
        food.brand = "Test brand"
        food.micronutrients = ["magnesium": .init(value: 80, unit: "mg")]
        food.generatedIconImageData = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return food
    }

    @Test func completedContainerRetainsFoodBankIDAndResolvesItsIcon() throws {
        let source = food()
        let container = TrackedContainer.from(source, startWeight: 300, gramsPerServing: 30)
        container.finalWeight = 240
        let entry = try #require(container.toNutritionEntry(mealType: .lunch))
        #expect(entry.savedFoodID == source.id)
        #expect(entry.calories == 320)
        #expect(entry.protein == 10)
        #expect(entry.micronutrients["magnesium"]?.value == 160)
        let duplicateName = food()
        let resolved = JournalFoodImageLookup.food(in: [duplicateName, source], entryID: entry.id, savedFoodID: entry.savedFoodID)
        #expect(resolved?.id == source.id)
        let imageBytes = try #require(resolved?.generatedIconImageData)
        #expect(UIImage(data: imageBytes) != nil)
    }

    @Test func sourceEditsDoNotChangeSnapshotNutritionButKeepIconLink() throws {
        let source = food()
        let container = TrackedContainer.from(source, startWeight: 300, gramsPerServing: 30)
        source.name = "Renamed Cashews"
        source.calories = 999
        source.archivedAt = .now
        container.finalWeight = 270
        let entry = try #require(container.toNutritionEntry())
        #expect(entry.name == "Cashews")
        #expect(entry.calories == 160)
        #expect(entry.savedFoodID == source.id)
        #expect(JournalFoodImageLookup.food(in: [source], entryID: entry.id, savedFoodID: entry.savedFoodID)?.id == source.id)
    }

    @Test func legacyUnlinkedContainerDoesNotGuessFromFoodName() throws {
        let source = food()
        let container = TrackedContainer.from(source, startWeight: 300, gramsPerServing: 30)
        container.savedFoodID = nil
        container.finalWeight = 270
        let entry = try #require(container.toNutritionEntry())
        #expect(entry.savedFoodID == nil)
        #expect(JournalFoodImageLookup.food(in: [source], entryID: entry.id, savedFoodID: nil) == nil)
    }

    @Test func tareLoggingStillPreservesTheSameFoodBankLink() throws {
        let source = food()
        let plan = TareFoodLogPlan(emptyContainerWeight: 100, loadedGrossWeight: 160, foodWeight: 60, gramsPerServing: 30)
        let entry = plan.makeNutritionEntry(from: source, mealType: .lunch)
        #expect(entry.savedFoodID == source.id)
        #expect(entry.calories == 320)
        #expect(JournalFoodImageLookup.food(in: [source], entryID: entry.id, savedFoodID: entry.savedFoodID)?.id == source.id)
    }
}
