import Foundation
import SwiftData
import Testing
@testable import OpenFoodJournal

@MainActor
struct NutritionStoreHealthSyncTests {
    @Test
    func journalMutationBoundarySchedulesHealthSyncForCreateEditMoveAndDelete() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: NutritionEntry.self,
            DailyLog.self,
            SavedFood.self,
            configurations: configuration
        )
        let health = TestChatHealth()
        health.isNutritionSyncEnabled = true
        let store = NutritionStore(
            modelContext: container.mainContext,
            healthSyncer: health,
            isHealthSyncEnabled: { health.isNutritionSyncEnabled }
        )
        let entry = NutritionEntry(
            name: "Centralized Mutation",
            calories: 200,
            protein: 10,
            carbs: 20,
            fat: 8
        )

        store.log(entry, to: Date(timeIntervalSince1970: 1_721_433_600))
        await waitUntil { health.syncedEntryIDs == [entry.id] }

        health.resetNutritionMutations()
        entry.calories = 250
        store.saveEntry(entry)
        await waitUntil { health.syncedEntryIDs == [entry.id] }

        health.resetNutritionMutations()
        store.moveEntry(entry, to: Date(timeIntervalSince1970: 1_721_520_000))
        await waitUntil { health.syncedEntryIDs == [entry.id] }

        health.resetNutritionMutations()
        store.delete(entry)
        await waitUntil { health.deletedEntryIDs == [entry.id] }

        #expect(store.fetchAllEntries().isEmpty)
    }

    @Test
    func healthSyncRemainsOffWhenTheUserHasDisabledIt() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: NutritionEntry.self,
            DailyLog.self,
            SavedFood.self,
            configurations: configuration
        )
        let health = TestChatHealth()
        let store = NutritionStore(
            modelContext: container.mainContext,
            healthSyncer: health,
            isHealthSyncEnabled: { false }
        )
        let entry = NutritionEntry(
            name: "Local Only",
            calories: 250,
            protein: 12,
            carbs: 30,
            fat: 9
        )

        store.log(entry, to: Date(timeIntervalSince1970: 1_721_433_600))
        await yieldForScheduledMutations()

        #expect(store.fetchAllEntries().map(\.id) == [entry.id])
        #expect(health.syncedEntryIDs.isEmpty)
        #expect(health.deletedEntryIDs.isEmpty)
    }

    @Test
    func pendingHealthReconciliationUsesPersistedSyncState() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: NutritionEntry.self,
            DailyLog.self,
            configurations: configuration
        )
        let store = NutritionStore(modelContext: container.mainContext)
        let entry = NutritionEntry(
            name: "Pending Export",
            calories: 149,
            protein: 22,
            carbs: 0,
            fat: 6
        )

        store.log(entry, to: Date(timeIntervalSince1970: 1_721_433_600))
        #expect(store.entriesNeedingHealthSync().map(\.id) == [entry.id])

        entry.healthKitSyncStatus = .synced
        entry.healthKitLastWriteHash = entry.healthKitWriteHash
        try container.mainContext.save()

        #expect(store.entriesNeedingHealthSync().isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
    }

    private func yieldForScheduledMutations() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}
