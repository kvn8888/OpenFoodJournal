// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(SyncService.self) private var syncService
    @Environment(UserGoals.self) private var userGoals

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
        .tabBarMinimizeBehavior(.never)
        // Pull from server on every launch. Uses incremental sync when possible
        // (only fetches records changed since last sync), full fetch otherwise.
        .task {
            await pullFromServer()
        }
    }

    private func pullFromServer() async {
        do {
            let response: SyncResponse
            if let lastSync = syncService.lastSyncDate {
                // Incremental sync — only records changed since last pull
                response = try await syncService.fetchChanges(since: lastSync)
            } else {
                // First launch or no prior sync — pull everything
                response = try await syncService.fetchAll()
            }
            nutritionStore.applySync(response, userGoals: userGoals)
        } catch {
            // Sync failure is non-fatal — local data still works
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
