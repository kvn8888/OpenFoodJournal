// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

@main
struct MacrosApp: App {
    private let modelContainer: ModelContainer
    @State private var nutritionStore: NutritionStore
    @State private var scanService = ScanService()
    @State private var syncService = SyncService()
    @State private var healthKitService = HealthKitService()
    @State private var userGoals = UserGoals()

    init() {
        let isTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let config = ModelConfiguration(
            isStoredInMemoryOnly: isTest
        )
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: NutritionEntry.self, DailyLog.self, SavedFood.self, TrackedContainer.self,
                configurations: config
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        modelContainer = container
        _nutritionStore = State(initialValue: NutritionStore(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .cursorAtEnd()
                .modelContainer(modelContainer)
                .environment(nutritionStore)
                .environment(scanService)
                .environment(syncService)
                .environment(healthKitService)
                .environment(userGoals)
                .task {
                    // Wire sync service into nutrition store
                    nutritionStore.syncService = syncService
                    
                    // Request HealthKit auth on first launch if user has previously enabled it
                    if UserDefaults.standard.bool(forKey: "healthkit.enabled") {
                        await healthKitService.requestAuthorization()
                    }
                }
        }
    }
}
