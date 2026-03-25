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

    @State private var showExportSheet = false
    @State private var csvContent: String = ""
    @State private var showOnboarding = false

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
                        csvContent = nutritionStore.exportCSV()
                        showExportSheet = true
                    } label: {
                        Label("Export as CSV", systemImage: "square.and.arrow.up")
                    }
                }

                // MARK: About
                Section("About") {
                    Button {
                        showOnboarding = true
                    } label: {
                        Label("Show Onboarding", systemImage: "hand.wave")
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
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                hasAPIKey = KeychainService.hasGeminiAPIKey
            }
        }
        .sheet(isPresented: $showExportSheet) {
            if !csvContent.isEmpty {
                ShareLink(
                    item: csvContent,
                    subject: Text("OpenFoodJournal Export"),
                    message: Text("My food log exported from OpenFoodJournal.")
                )
                .presentationDetents([.medium])
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
    }
}

#Preview {
    SettingsView()
        .environment(NutritionStore(modelContext: ModelContainer.preview.mainContext))
        .environment(HealthKitService())
        .environment(UserGoals())
}
