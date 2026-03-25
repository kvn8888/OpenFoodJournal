// OpenFoodJournal — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(HealthKitService.self) private var healthKit
    @Environment(UserGoals.self) private var goals

    @AppStorage("healthkit.enabled") private var healthKitEnabled: Bool = false

    /// The text field value for the API key — loaded from Keychain on appear.
    @State private var apiKeyInput: String = ""
    /// Whether the saved key is currently masked (showing dots instead of the key).
    @State private var isKeyMasked: Bool = true
    /// Whether a valid API key is currently stored in Keychain.
    @State private var hasAPIKey: Bool = false

    @State private var showOnboarding = false
    /// Shown when the user tries to export but has logged no food yet.
    @State private var showNoDataAlert = false

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

                // MARK: Gemini API Key
                Section {
                    if hasAPIKey && apiKeyInput.isEmpty {
                        // Key is saved — show masked or reveal toggle
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("API key saved")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") {
                                KeychainService.delete(for: KeychainService.geminiAPIKeyAccount)
                                hasAPIKey = false
                                apiKeyInput = ""
                            }
                            .foregroundStyle(.red)
                            .font(.subheadline)
                        }
                    } else {
                        // No key or user is editing — show text field
                        HStack {
                            SecureField("Paste your Gemini API key", text: $apiKeyInput)
                                .textContentType(.password)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            if !apiKeyInput.isEmpty {
                                Button("Save") {
                                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else { return }
                                    KeychainService.save(trimmed, for: KeychainService.geminiAPIKeyAccount)
                                    hasAPIKey = true
                                    apiKeyInput = ""  // Clear the field to show "saved" state
                                }
                                .buttonStyle(.borderedProminent)
                                .font(.subheadline)
                            }
                        }
                    }
                } header: {
                    Text("Gemini API Key")
                } footer: {
                    Text("Required for food scanning. Get a free key at [aistudio.google.com](https://aistudio.google.com/apikey)")
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
                }

                // MARK: Data
                Section("Data") {
                    Button {
                        presentCSVExport()
                    } label: {
                        Label("Export as CSV", systemImage: "square.and.arrow.up")
                    }
                    .alert("Nothing to export", isPresented: $showNoDataAlert) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Log some food first, then export your data.")
                    }
                }

                // MARK: About
                Section("About") {
                    Button {
                        showOnboarding = true
                    } label: {
                        Label("Show Onboarding", systemImage: "hand.wave")
                    }

                    // Health/nutrition citation page — satisfies App Store Guideline 1.4.1
                    NavigationLink {
                        HealthDisclaimerView()
                    } label: {
                        Label("Sources & Disclaimers", systemImage: "info.circle")
                    }

                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/kvn8888/OpenFoodJournal")!) {
                        Label("Source Code (AGPL-3.0)", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    Link(destination: URL(string: "https://github.com/kvn8888/OpenFoodJournal/blob/main/PRIVACY.md")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }

                    Link(destination: URL(string: "https://github.com/kvn8888/OpenFoodJournal/issues")!) {
                        Label("Report a Bug", systemImage: "ant.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                hasAPIKey = KeychainService.hasGeminiAPIKey
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
    }

    // MARK: - CSV Export

    /// Generates the CSV, writes it to a temp .csv file, and presents the
    /// system share sheet in one tap — no intermediate sheet required.
    /// The file gets the correct .csv extension so Numbers / Excel recognise it.
    private func presentCSVExport() {
        let csv = nutritionStore.exportCSV()
        guard !csv.isEmpty else {
            showNoDataAlert = true
            return
        }

        // Write to a temp file so the share sheet knows the MIME type (.csv)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFoodJournal-Export.csv")
        guard let _ = try? csv.write(to: tmpURL, atomically: true, encoding: .utf8) else { return }

        // Find the key window to present the UIKit share sheet from
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }

        let activityVC = UIActivityViewController(
            activityItems: [tmpURL],  // sharing a URL gives the file a name + extension
            applicationActivities: nil
        )
        root.present(activityVC, animated: true)
    }
}

#Preview {
    SettingsView()
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(HealthKitService())
        .environment(UserGoals())
}
