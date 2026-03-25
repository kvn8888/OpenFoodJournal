// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

@main
struct MacrosApp: App {
    private let modelContainer: ModelContainer
    @State private var nutritionStore: NutritionStore
    @State private var scanService = ScanService()
    @State private var healthKitService = HealthKitService()
    @State private var userGoals = UserGoals()

    init() {
        let isTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let config: ModelConfiguration
        if isTest {
            // Tests use in-memory store without CloudKit
            config = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            // Production: sync via CloudKit private database
            config = ModelConfiguration(
                cloudKitDatabase: .private("iCloud.k3vnc.OpenFoodJournal")
            )
        }
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: NutritionEntry.self, DailyLog.self, SavedFood.self, TrackedContainer.self, Preferences.self,
                configurations: config
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        modelContainer = container
        _nutritionStore = State(initialValue: NutritionStore(modelContext: container.mainContext))

        // Ensure the Preferences singleton exists in SwiftData
        _ = Preferences.current(in: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .cursorAtEnd()
                .modelContainer(modelContainer)
                .environment(nutritionStore)
                .environment(scanService)
                .environment(healthKitService)
                .environment(userGoals)
                .task {
                    // Request HealthKit auth on first launch if user has previously enabled it
                    if UserDefaults.standard.bool(forKey: "healthkit.enabled") {
                        await healthKitService.requestAuthorization()
                    }
                }
        }
    }
}
