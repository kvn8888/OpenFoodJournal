import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

struct ContainerTrackingTests {
    @Test
    func tareCalculationDerivesFoodAdded() {
        let calculation = ContainerWeightCalculation(
            tareWeight: 350,
            initialGrossWeight: 500,
            endingGrossWeight: nil
        )

        #expect(calculation.isValidStart)
        #expect(calculation.initialFoodWeight == 150)
        #expect(calculation.consumedFoodWeight == nil)
        #expect(calculation.remainingFoodWeight == nil)
    }

    @Test
    func tareCalculationPreservesDecimalMeasurements() {
        let calculation = ContainerWeightCalculation(
            tareWeight: 203.25,
            initialGrossWeight: 512.5,
            endingGrossWeight: 401.75
        )

        #expect(calculation.isValidStart)
        #expect(calculation.isValidCompletion)
        #expect(calculation.initialFoodWeight == 309.25)
        #expect(calculation.consumedFoodWeight == 110.75)
        #expect(calculation.remainingFoodWeight == 198.5)
    }

    @Test
    func tareCalculationRejectsInvalidStartingMeasurements() {
        let equalWeights = ContainerWeightCalculation(
            tareWeight: 350,
            initialGrossWeight: 350,
            endingGrossWeight: nil
        )
        let loadedBelowTare = ContainerWeightCalculation(
            tareWeight: 350,
            initialGrossWeight: 300,
            endingGrossWeight: nil
        )
        let zeroTare = ContainerWeightCalculation(
            tareWeight: 0,
            initialGrossWeight: 500,
            endingGrossWeight: nil
        )

        #expect(!equalWeights.isValidStart)
        #expect(!loadedBelowTare.isValidStart)
        #expect(!zeroTare.isValidStart)
        #expect(equalWeights.initialFoodWeight == nil)
    }

    @Test
    func tareCalculationRejectsCompletionBelowEmptyContainer() {
        let calculation = ContainerWeightCalculation(
            tareWeight: 350,
            initialGrossWeight: 500,
            endingGrossWeight: 349.9
        )

        #expect(!calculation.isValidCompletion)
    }

    @Test
    func tareCalculationTracksConsumedAndRemainingFood() {
        let calculation = ContainerWeightCalculation(
            tareWeight: 350,
            initialGrossWeight: 500,
            endingGrossWeight: 400
        )

        #expect(calculation.isValidCompletion)
        #expect(calculation.consumedFoodWeight == 100)
        #expect(calculation.remainingFoodWeight == 50)
    }

    @Test
    func endingAtTareRepresentsFullConsumption() {
        let calculation = ContainerWeightCalculation(
            tareWeight: 350,
            initialGrossWeight: 500,
            endingGrossWeight: 350
        )

        #expect(calculation.isValidCompletion)
        #expect(calculation.consumedFoodWeight == 150)
        #expect(calculation.remainingFoodWeight == 0)
    }

    @Test
    func legacyCalculationWithoutTareKeepsConsumptionBehavior() {
        let calculation = ContainerWeightCalculation(
            tareWeight: nil,
            initialGrossWeight: 500,
            endingGrossWeight: 400
        )

        #expect(calculation.isValidStart)
        #expect(calculation.isValidCompletion)
        #expect(calculation.initialFoodWeight == nil)
        #expect(calculation.consumedFoodWeight == 100)
        #expect(calculation.remainingFoodWeight == nil)
    }

    @Test
    func tareContainerScalesMacrosAndMicronutrientsFromConsumedWeight() throws {
        let container = TrackedContainer(
            foodName: "Test Food",
            caloriesPerServing: 100,
            proteinPerServing: 5,
            carbsPerServing: 10,
            fatPerServing: 2,
            micronutrientsPerServing: [
                "sodium": MicronutrientValue(value: 200, unit: "mg"),
                "fiber": MicronutrientValue(value: 4, unit: "g")
            ],
            gramsPerServing: 50,
            tareWeight: 350,
            startWeight: 500
        )
        container.finalWeight = 400

        #expect(container.initialFoodGrams == 150)
        #expect(container.consumedGrams == 100)
        #expect(container.remainingFoodGrams == 50)
        #expect(container.consumedServings == 2)
        #expect(container.consumedCalories == 200)
        #expect(container.consumedProtein == 10)
        #expect(container.consumedCarbs == 20)
        #expect(container.consumedFat == 4)
        let consumedMicronutrients = try #require(container.consumedMicronutrients)
        #expect(consumedMicronutrients["sodium"]?.value == 400)
        #expect(consumedMicronutrients["sodium"]?.unit == "mg")
        #expect(consumedMicronutrients["fiber"]?.value == 8)
        #expect(consumedMicronutrients["fiber"]?.unit == "g")

        let entry = try #require(container.toNutritionEntry(mealType: .lunch))
        #expect(entry.calories == 200)
        #expect(entry.protein == 10)
        #expect(entry.carbs == 20)
        #expect(entry.fat == 4)
        #expect(entry.micronutrients["sodium"]?.value == 400)
        #expect(entry.micronutrients["fiber"]?.value == 8)
    }

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
    func tareStartAndEndWeightsPersistAndRoundTripThroughBackupRecord() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let modelContainer = try ModelContainer(
            for: TrackedContainer.self,
            configurations: configuration
        )
        let context = modelContainer.mainContext
        let tracked = makeContainer(
            savedFoodID: UUID(),
            tareWeight: 102.25,
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

        #expect(reloaded.tareWeight == 102.25)
        #expect(reloaded.startWeight == 512.5)
        #expect(reloaded.finalWeight == 203.25)

        let encodedRecord = try JSONEncoder().encode(TrackedContainerRecord(reloaded))
        let decodedRecord = try JSONDecoder().decode(
            TrackedContainerRecord.self,
            from: encodedRecord
        )

        #expect(decodedRecord.tareWeight == 102.25)
        #expect(decodedRecord.startWeight == 512.5)
        #expect(decodedRecord.finalWeight == 203.25)

        let restored = decodedRecord.makeModel()
        #expect(restored.tareWeight == 102.25)
        #expect(restored.startWeight == 512.5)
        #expect(restored.finalWeight == 203.25)

        let updated = makeContainer(
            savedFoodID: UUID(),
            startWeight: 1,
            finalWeight: nil,
            startDate: .distantPast,
            completedDate: nil
        )
        decodedRecord.apply(to: updated)
        #expect(updated.tareWeight == 102.25)
        #expect(updated.startWeight == 512.5)
        #expect(updated.finalWeight == 203.25)
    }

    @MainActor
    @Test
    func legacyBackupWithoutTareWeightDecodesAsNil() throws {
        let tracked = makeContainer(
            savedFoodID: UUID(),
            tareWeight: 100,
            startWeight: 500,
            finalWeight: 300,
            startDate: Date(timeIntervalSince1970: 100),
            completedDate: Date(timeIntervalSince1970: 200)
        )
        let encoded = try JSONEncoder().encode(TrackedContainerRecord(tracked))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "tareWeight")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TrackedContainerRecord.self, from: legacyData)
        let restored = decoded.makeModel()

        #expect(decoded.tareWeight == nil)
        #expect(restored.tareWeight == nil)
        #expect(restored.startWeight == 500)
        #expect(restored.finalWeight == 300)
        #expect(restored.consumedGrams == 200)
    }

    @MainActor
    @Test
    func tursoSchemaAndTrackedContainerRowIncludeTareWeight() {
        let table = TursoSchema.tables.first { $0.name == "ofj_tracked_containers" }
        #expect(table?.columns.contains(where: { $0.name == "tare_weight" && $0.type == "REAL" }) == true)

        let tracked = makeContainer(
            savedFoodID: UUID(),
            tareWeight: 350,
            startWeight: 500,
            finalWeight: 400,
            startDate: Date(timeIntervalSince1970: 100),
            completedDate: Date(timeIntervalSince1970: 200)
        )
        let row = TursoMirrorService.trackedContainerMirrorRow(
            tracked,
            generation: "test-generation",
            startDate: "1970-01-01T00:01:40.000Z",
            completedDate: "1970-01-01T00:03:20.000Z",
            micronutrientsJSON: "{}"
        )

        #expect(row.table == "ofj_tracked_containers")
        #expect(row.columns["tare_weight"] == .real(350))
        #expect(row.columns["start_weight"] == .real(500))
        #expect(row.columns["final_weight"] == .real(400))

        tracked.tareWeight = nil
        let legacyRow = TursoMirrorService.trackedContainerMirrorRow(
            tracked,
            generation: "test-generation",
            startDate: "1970-01-01T00:01:40.000Z",
            completedDate: nil,
            micronutrientsJSON: "{}"
        )
        #expect(legacyRow.columns["tare_weight"] == .null)
    }

    private func makeContainer(
        savedFoodID: UUID,
        tareWeight: Double? = nil,
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
            tareWeight: tareWeight,
            startWeight: startWeight,
            startDate: startDate,
            savedFoodID: savedFoodID
        )
        container.finalWeight = finalWeight
        container.completedDate = completedDate
        return container
    }
}
