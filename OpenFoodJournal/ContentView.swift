// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(NutritionStore.self) private var nutritionStore
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
