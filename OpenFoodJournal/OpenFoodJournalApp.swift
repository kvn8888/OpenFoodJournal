// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

@main
struct MacrosApp: App {
    private let modelContainer: ModelContainer
    @State private var nutritionStore: NutritionStore
    @State private var scanService: ScanService
    @State private var tursoMirrorService: TursoMirrorService
    @State private var healthKitService: HealthKitService
    @State private var userGoals = UserGoals()
    @State private var mealTimeSettings = MealTimeSettings()
    @State private var offService = OpenFoodFactsService()
    @Environment(\.scenePhase) private var scenePhase

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
                for: NutritionEntry.self, DailyLog.self, SavedFood.self, TrackedContainer.self, Preferences.self, GeminiScanLog.self, GeminiCostAccumulator.self,
                configurations: config
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        modelContainer = container
        let tursoMirror = TursoMirrorService(modelContext: container.mainContext)
        _tursoMirrorService = State(initialValue: tursoMirror)
        let health = HealthKitService(tursoMirror: tursoMirror)
        _healthKitService = State(initialValue: health)
        let store = NutritionStore(
            modelContext: container.mainContext,
            tursoMirror: tursoMirror,
            healthSyncer: health,
            isHealthSyncEnabled: {
                UserDefaults.standard.bool(forKey: "healthkit.enabled")
            }
        )
        _nutritionStore = State(initialValue: store)
        _scanService = State(initialValue: ScanService(
            modelContext: container.mainContext,
            tursoMirror: tursoMirror
        ))

        // Ensure the Preferences singleton exists in SwiftData
        _ = Preferences.current(in: container.mainContext)
        _ = GeminiCostAccumulator.current(in: container.mainContext)
    }

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasRetrolinkedMappings") private var hasRetrolinkedMappings = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
                    .cursorAtEnd()
                    .modelContainer(modelContainer)
                    .environment(nutritionStore)
                    .environment(scanService)
                    .environment(tursoMirrorService)
                    .environment(healthKitService)
                    .environment(userGoals)
                    .environment(mealTimeSettings)
                    .environment(offService)
                    .task {
                        // Keep entry/day relationships healthy after CloudKit sync or app updates.
                        nutritionStore.repairDailyLogEntryRelationships()
                        await reconcilePendingHealthKitEntries()

                        // One-time migration: link old entries to SavedFoods and dedup mappings
                        if !hasRetrolinkedMappings {
                            nutritionStore.deduplicateAllMappings()
                            nutritionStore.retrolinkOrphanedEntries()
                            hasRetrolinkedMappings = true
                        }
                        tursoMirrorService.scheduleMirror(reason: "app_launch")
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            tursoMirrorService.scheduleMirror(reason: "app_foreground")
                            Task {
                                await reconcilePendingHealthKitEntries()
                            }
                        }
                    }
            } else {
                OnboardingView()
                    .modelContainer(modelContainer)
                    .environment(nutritionStore)
                    .environment(scanService)
                    .environment(tursoMirrorService)
                    .environment(healthKitService)
                    .environment(userGoals)
                    .environment(mealTimeSettings)
                    .environment(offService)
            }
        }
    }

    /// HealthKit is a derived export target, so any mutation interrupted by
    /// backgrounding or an older app build must be reconciled from SwiftData.
    /// This also repairs Assistant-created entries that predate centralized
    /// mutation-side synchronization.
    private func reconcilePendingHealthKitEntries() async {
        guard UserDefaults.standard.bool(forKey: "healthkit.enabled") else { return }
        if !healthKitService.isAuthorized {
            await healthKitService.requestAuthorization()
        }
        guard healthKitService.isAuthorized else { return }

        let pending = nutritionStore.entriesNeedingHealthSync()
        guard !pending.isEmpty else { return }
        _ = await healthKitService.syncMissingEntries(
            pending,
            in: modelContainer.mainContext
        )
    }
}
