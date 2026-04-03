// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var userGoals

    // Tracks the last version the user saw What's New for.
    // When the app version changes, the sheet is shown again.
    @AppStorage("lastSeenVersion") private var lastSeenVersion: String = ""
    @State private var showWhatsNew = false

    /// The current app version from Info.plist (e.g. "1.1")
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

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
        .onAppear {
            // Show What's New sheet if the user hasn't seen this version yet
            if lastSeenVersion != currentVersion {
                showWhatsNew = true
            }
        }
        .sheet(isPresented: $showWhatsNew, onDismiss: {
            // Mark this version as seen so the sheet isn't shown again
            lastSeenVersion = currentVersion
        }) {
            WhatsNewSheet()
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
