import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

@MainActor
struct FoodIconGenerationQueueTests {
    @Test
    func automaticPolicyRequiresOptInImageModeAndMissingImage() {
        #expect(FoodIconGenerationPolicy.shouldAutomaticallyGenerate(
            isGenerationEnabled: true,
            usesGeneratedImages: true,
            needsGeneratedImage: true
        ))
        #expect(!FoodIconGenerationPolicy.shouldAutomaticallyGenerate(
            isGenerationEnabled: false,
            usesGeneratedImages: true,
            needsGeneratedImage: true
        ))
        #expect(!FoodIconGenerationPolicy.shouldAutomaticallyGenerate(
            isGenerationEnabled: true,
            usesGeneratedImages: false,
            needsGeneratedImage: true
        ))
        #expect(!FoodIconGenerationPolicy.shouldAutomaticallyGenerate(
            isGenerationEnabled: true,
            usesGeneratedImages: true,
            needsGeneratedImage: false
        ))
    }

    @Test
    func queueIsFIFOAndDeduplicatesPendingAndActiveFoods() throws {
        let first = UUID()
        let second = UUID()
        var queue = FoodIconGenerationQueue()

        let enqueuedFirst = queue.enqueue(first)
        let rejectedPendingDuplicate = queue.enqueue(first)
        let enqueuedSecond = queue.enqueue(second)
        #expect(enqueuedFirst)
        #expect(!rejectedPendingDuplicate)
        #expect(enqueuedSecond)
        #expect(queue.pendingCount == 2)
        #expect(queue.outstandingCount == 2)

        let beganFirst = queue.beginNext()
        let rejectedActiveDuplicate = queue.enqueue(first)
        let refusedParallelStart = queue.beginNext()
        #expect(beganFirst == first)
        #expect(!rejectedActiveDuplicate)
        #expect(refusedParallelStart == nil)
        #expect(queue.outstandingCount == 2)

        queue.finishActive()
        let beganSecond = queue.beginNext()
        #expect(beganSecond == second)
        queue.finishActive()
        #expect(queue.isEmpty)
    }

    @Test
    func savedFoodIsQueuedOnlyAfterCanonicalPersistenceSucceeds() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: NutritionEntry.self,
            DailyLog.self,
            SavedFood.self,
            configurations: configuration
        )
        let store = NutritionStore(modelContext: container.mainContext)
        let recorder = RecordingFoodImageGenerationQueue()
        store.configureFoodImageGenerationQueue(recorder)
        let food = SavedFood(
            name: "Queue Test",
            calories: 120,
            protein: 4,
            carbs: 20,
            fat: 3
        )

        #expect(store.addSavedFood(food))

        let persisted = try container.mainContext.fetch(FetchDescriptor<SavedFood>())
        #expect(persisted.map(\.id) == [food.id])
        #expect(recorder.foodIDs == [food.id])
    }
}

@MainActor
private final class RecordingFoodImageGenerationQueue: SavedFoodImageGenerationQueuing {
    private(set) var foodIDs: [UUID] = []

    func enqueueFoodIconImageGeneration(for foodID: UUID) {
        foodIDs.append(foodID)
    }
}
