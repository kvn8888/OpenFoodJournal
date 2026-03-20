// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(HealthKitService.self) private var healthKit
    @Environment(UserGoals.self) private var goals

    @AppStorage("healthkit.enabled") private var healthKitEnabled: Bool = false
    @AppStorage("retain.source.images") private var retainSourceImages: Bool = true

    @State private var showExportSheet = false
    @State private var csvContent: String = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Goals
                Section("Goals") {
                    NavigationLink("Daily Macro Goals") {
                        GoalsEditorView()
                    }
                    HStack {
                        Text("Calories")
                        Spacer()
                        Text("\(Int(goals.dailyCalories)) kcal")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Protein / Carbs / Fat")
                        Spacer()
                        Text("\(Int(goals.dailyProtein))g · \(Int(goals.dailyCarbs))g · \(Int(goals.dailyFat))g")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }

                // MARK: Integrations
                Section("Integrations") {
                    Toggle(isOn: $healthKitEnabled) {
                        Label("Write to Apple Health", systemImage: "heart.fill")
                            .foregroundStyle(.red)
                    }
                    .onChange(of: healthKitEnabled) { _, enabled in
                        if enabled {
                            Task { await healthKit.requestAuthorization() }
                        }
                    }

                    if healthKitEnabled && !healthKit.isAuthorized {
                        Label("Authorization required — tap above to grant access.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Label("iCloud Sync", systemImage: "icloud")
                        Spacer()
                        Text("Automatic")
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Data
                Section("Data") {
                    Toggle(isOn: $retainSourceImages) {
                        Label("Save scan photos", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        csvContent = nutritionStore.exportCSV()
                        showExportSheet = true
                    } label: {
                        Label("Export as CSV", systemImage: "square.and.arrow.up")
                    }
                }

                // MARK: About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/openFoodJournal/macros")!) {
                        Label("Source Code (AGPL-3.0)", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    Link(destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!) {
                        Label("License", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $showExportSheet) {
            if !csvContent.isEmpty {
                ShareLink(
                    item: csvContent,
                    subject: Text("Macros Journal Export"),
                    message: Text("My food log exported from Macros.")
                )
                .presentationDetents([.medium])
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(HealthKitService())
        .environment(UserGoals())
}
