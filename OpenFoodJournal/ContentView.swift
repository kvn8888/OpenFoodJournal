// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct ContentView: View {
    // Access the shared store and sync service injected by OpenFoodJournalApp
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(SyncService.self) private var syncService

    var body: some View {
        TabView {
            Tab("Journal", systemImage: "book.pages") {
                DailyLogView()
            }
            Tab("Food Bank", systemImage: "refrigerator") {
                FoodBankView()
            }
            Tab("History", systemImage: "chart.xyaxis.line") {
                HistoryView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // On first launch (SwiftData is empty) pull all data from the server.
        // Subsequent launches skip the fetch — local data is the authoritative source.
        .task {
            let logs = nutritionStore.fetchAllLogs()
            guard logs.isEmpty else { return }   // already seeded

            if let response = try? await syncService.fetchAll() {
                nutritionStore.applySync(response)
            }
        }
    }
}

#Preview {
    let container = ModelContainer.preview
    ContentView()
        .modelContainer(container)
        .environment(NutritionStore(modelContext: container.mainContext))
        .environment(ScanService())
        .environment(HealthKitService())
        .environment(UserGoals())
}
