import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

struct ContainerTrackingTests {
    @Test
    func mostRecentEndWeightUsesLatestCompletedRecordForFood() {
        let foodID = UUID()
        let otherFoodID = UUID()
        let older = makeContainer(
            savedFoodID: foodID,
            startWeight: 500,
            finalWeight: 350,
            startDate: Date(timeIntervalSince1970: 100),
            completedDate: Date(timeIntervalSince1970: 200)
        )
        let newer = makeContainer(
            savedFoodID: foodID,
            startWeight: 350,
            finalWeight: 225.5,
            startDate: Date(timeIntervalSince1970: 300),
            completedDate: Date(timeIntervalSince1970: 400)
        )
        let active = makeContainer(
            savedFoodID: foodID,
            startWeight: 225.5,
            finalWeight: nil,
            startDate: Date(timeIntervalSince1970: 500),
            completedDate: nil
        )
        let otherFood = makeContainer(
            savedFoodID: otherFoodID,
            startWeight: 700,
            finalWeight: 100,
            startDate: Date(timeIntervalSince1970: 600),
            completedDate: Date(timeIntervalSince1970: 700)
        )

        let result = TrackedContainer.mostRecentEndWeight(
            for: foodID,
            in: [active, older, otherFood, newer]
        )

        #expect(result == 225.5)
    }

    @MainActor
    @Test
    func startAndEndWeightsPersistAndRoundTripThroughBackupRecord() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let modelContainer = try ModelContainer(
            for: TrackedContainer.self,
            configurations: configuration
        )
        let context = modelContainer.mainContext
        let tracked = makeContainer(
            savedFoodID: UUID(),
            startWeight: 512.5,
            finalWeight: 203.25,
            startDate: Date(timeIntervalSince1970: 100),
            completedDate: Date(timeIntervalSince1970: 200)
        )
        let trackedID = tracked.id

        context.insert(tracked)
        try context.save()

        let reloadedContext = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<TrackedContainer>(
            predicate: #Predicate { $0.id == trackedID }
        )
        descriptor.fetchLimit = 1
        let reloaded = try #require(try reloadedContext.fetch(descriptor).first)

        #expect(reloaded.startWeight == 512.5)
        #expect(reloaded.finalWeight == 203.25)

        let encodedRecord = try JSONEncoder().encode(TrackedContainerRecord(reloaded))
        let decodedRecord = try JSONDecoder().decode(
            TrackedContainerRecord.self,
            from: encodedRecord
        )

        #expect(decodedRecord.startWeight == 512.5)
        #expect(decodedRecord.finalWeight == 203.25)
    }

    private func makeContainer(
        savedFoodID: UUID,
        startWeight: Double,
        finalWeight: Double?,
        startDate: Date,
        completedDate: Date?
    ) -> TrackedContainer {
        let container = TrackedContainer(
            foodName: "Test Food",
            caloriesPerServing: 100,
            proteinPerServing: 5,
            carbsPerServing: 10,
            fatPerServing: 2,
            gramsPerServing: 50,
            startWeight: startWeight,
            startDate: startDate,
            savedFoodID: savedFoodID
        )
        container.finalWeight = finalWeight
        container.completedDate = completedDate
        return container
    }
}
