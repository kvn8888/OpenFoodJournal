// OpenFoodJournal — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(HealthKitService.self) private var healthKit
    @Environment(UserGoals.self) private var goals
    @Environment(TursoMirrorService.self) private var tursoMirror
    @Query private var geminiCostAccumulators: [GeminiCostAccumulator]

    @AppStorage("healthkit.enabled") private var healthKitEnabled: Bool = false
    @AppStorage("scan.useProModel") private var useProModel: Bool = false
    @AppStorage("off.contributeEnabled") private var offContributeEnabled: Bool = false
    @AppStorage("off.contributionSuccessCount") private var offContributionSuccessCount: Int = 0
    @AppStorage("off.lastContributionAt") private var offLastContributionAt: Double = 0

    /// The text field value for the API key — loaded from Keychain on appear.
    @State private var apiKeyInput: String = ""
    /// Whether the saved key is currently masked (showing dots instead of the key).
    @State private var isKeyMasked: Bool = true
    /// Whether a valid API key is currently stored in Keychain.
    @State private var hasAPIKey: Bool = false

    @State private var showOnboarding = false
    /// Shown when the user tries to export but has logged no food yet.
    @State private var showNoDataAlert = false
    @State private var showNoGeminiLogsAlert = false
    @State private var showBackupImporter = false
    @State private var showBackupImportConfirmation = false
    @State private var showBackupImportSuccess = false
    @State private var showBackupImportError = false
    @State private var pendingBackup: OpenFoodJournalBackup?
    @State private var backupImportSummary: BackupImportSummary?
    @State private var backupImportErrorMessage = ""
    @State private var showResetGeminiCostConfirmation = false
    @State private var isSyncingHealthKit = false
    @State private var showHealthKitSyncResult = false
    @State private var healthKitSyncResultMessage = ""

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

                // MARK: Scanning
                Section {
                    Toggle(isOn: $useProModel) {
                        Label("Use Gemini Pro for AI", systemImage: "sparkles")
                    }
                } header: {
                    Text("Scanning")
                } footer: {
                    Text("When enabled, food photo scans and AI Search use Gemini Pro for more accurate estimates. Lite mode is faster and uses less API quota.")
                }

                // MARK: Gemini Usage
                Section {
                    LabeledContent {
                        Text(costText(geminiTotalEstimatedCostUSD))
                            .monospacedDigit()
                    } label: {
                        Label("Estimated Token Cost", systemImage: "dollarsign.circle")
                    }

                    LabeledContent("Requests", value: geminiRequestSummaryText)
                    LabeledContent("Tokens", value: geminiTokenSummaryText)

                    if geminiTotalThinkingTokens > 0 {
                        LabeledContent("Thinking Tokens", value: geminiTotalThinkingTokens.formatted())
                    }

                    if geminiGroundedSearchPrompts > 0 {
                        LabeledContent("AI Search Grounding", value: "\(geminiGroundedSearchPrompts.formatted()) prompts")
                    }

                    if geminiTotalRequests > 0 {
                        LabeledContent("Last Estimate", value: geminiLastEstimateText)
                    }

                    Button(role: .destructive) {
                        showResetGeminiCostConfirmation = true
                    } label: {
                        Label("Reset Gemini Usage Total", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(geminiTotalRequests == 0)
                } header: {
                    Text("Gemini Usage")
                } footer: {
                    Text("Estimated from Gemini token usage and Google Standard paid-tier prices checked June 19, 2026. Google Search grounding fees are not included because the API response does not expose the number of billable search queries.")
                }

                // MARK: Integrations
                Section {
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

                    LabeledContent("Pending Health Sync", value: healthKitPendingSyncCount.formatted())

                    Button {
                        performHealthKitBackfill()
                    } label: {
                        if isSyncingHealthKit {
                            Label("Syncing Nutrition to Apple Health", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Sync Missing Nutrition to Apple Health", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(!healthKitEnabled || isSyncingHealthKit)

                    Toggle(isOn: $offContributeEnabled) {
                        Label("Contribute to Open Food Facts", systemImage: "globe.americas")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Contribution Status", systemImage: "checkmark.seal")
                        Text(offContributionStatusText)
                            .font(.caption)
                            .foregroundStyle(offContributionSuccessCount > 0 ? .green : .secondary)
                    }
                } header: {
                    Text("Integrations")
                } footer: {
                    Text("Apple Health sync only replaces samples written by OpenFoodJournal. OpenFoodJournal records successful Open Food Facts uploads on this device; if the status stays at zero, no contribution has been confirmed.")
                }

                // MARK: Data
                Section {
                    NavigationLink {
                        TursoIntegrationSettingsView()
                    } label: {
                        Label("Turso Integration", systemImage: "externaldrive.badge.icloud")
                    }

                    Button {
                        presentCSVExport()
                    } label: {
                        Label("Export Spreadsheet CSV", systemImage: "tablecells")
                    }
                    .alert("Nothing to export", isPresented: $showNoDataAlert) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Log some food first, then export your data.")
                    }

                    Button {
                        presentBackupExport()
                    } label: {
                        Label("Export Backup", systemImage: "externaldrive")
                    }

                    Button {
                        presentGeminiLogExport()
                    } label: {
                        Label("Export Gemini Logs", systemImage: "doc.text.magnifyingglass")
                    }
                    .alert("No Gemini logs", isPresented: $showNoGeminiLogsAlert) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Gemini scan and AI Search logs from the last 30 days will appear here after you use those features.")
                    }

                    Button {
                        showBackupImporter = true
                    } label: {
                        Label("Import Backup", systemImage: "tray.and.arrow.down")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Your journal is stored locally and in your private iCloud database. Optional Turso mirroring sends a push-only copy to a Turso database you configure.")
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
                _ = GeminiCostAccumulator.current(in: modelContext)
                try? modelContext.save()
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .fileImporter(
            isPresented: $showBackupImporter,
            allowedContentTypes: [.json]
        ) { result in
            handleBackupImportSelection(result)
        }
        .confirmationDialog(
            "Import Backup?",
            isPresented: $showBackupImportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Import Backup") {
                performBackupImport()
            }
            Button("Cancel", role: .cancel) {
                pendingBackup = nil
            }
        } message: {
            Text("This upserts records by UUID, so importing the same backup again updates existing data instead of duplicating it.\n\n\(pendingBackup?.importSummaryText ?? "")")
        }
        .alert("Backup Imported", isPresented: $showBackupImportSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupImportSummary?.message ?? "")
        }
        .alert("Backup Import Failed", isPresented: $showBackupImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupImportErrorMessage)
        }
        .alert("Apple Health Sync", isPresented: $showHealthKitSyncResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(healthKitSyncResultMessage)
        }
        .confirmationDialog(
            "Reset Gemini Usage Total?",
            isPresented: $showResetGeminiCostConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Total", role: .destructive) {
                resetGeminiCostTotals()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the local estimated cost and token counters. It does not affect Google billing history.")
        }
    }

    private var geminiTotalEstimatedCostUSD: Double {
        geminiCostAccumulators.reduce(0) { $0 + $1.totalEstimatedTokenCostUSD }
    }

    private var geminiTotalInputTokens: Int {
        geminiCostAccumulators.reduce(0) { $0 + $1.totalInputTokens }
    }

    private var geminiTotalOutputTokens: Int {
        geminiCostAccumulators.reduce(0) { $0 + $1.totalOutputTokens }
    }

    private var geminiTotalThinkingTokens: Int {
        geminiCostAccumulators.reduce(0) { $0 + $1.totalThinkingTokens }
    }

    private var geminiTotalRequests: Int {
        geminiCostAccumulators.reduce(0) { $0 + $1.totalRequests }
    }

    private var geminiSuccessfulRequests: Int {
        geminiCostAccumulators.reduce(0) { $0 + $1.successfulRequests }
    }

    private var geminiFailedRequests: Int {
        geminiCostAccumulators.reduce(0) { $0 + $1.failedRequests }
    }

    private var geminiGroundedSearchPrompts: Int {
        geminiCostAccumulators.reduce(0) { $0 + $1.groundedSearchPrompts }
    }

    private var geminiLastAccumulator: GeminiCostAccumulator? {
        geminiCostAccumulators
            .compactMap { accumulator -> (GeminiCostAccumulator, Date)? in
                guard let date = accumulator.lastRecordedAt else { return nil }
                return (accumulator, date)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private var geminiRequestSummaryText: String {
        "\(geminiTotalRequests.formatted()) total, \(geminiSuccessfulRequests.formatted()) ok, \(geminiFailedRequests.formatted()) failed"
    }

    private var geminiTokenSummaryText: String {
        "\(geminiTotalInputTokens.formatted()) in, \(geminiTotalOutputTokens.formatted()) out"
    }

    private var geminiLastEstimateText: String {
        guard let last = geminiLastAccumulator else {
            return "None yet"
        }

        let model = last.lastModel ?? "Unknown model"
        return "\(costText(last.lastEstimatedTokenCostUSD)) · \(model)"
    }

    private func costText(_ value: Double) -> String {
        guard value > 0 else { return "$0.0000" }
        if value < 0.0001 { return "<$0.0001" }
        return String(format: "$%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private var entriesNeedingHealthKitSync: [NutritionEntry] {
        _ = nutritionStore.changeCount
        return nutritionStore.fetchAllEntries().filter { entry in
            entry.healthKitSyncStatus != HealthKitSyncStatus.synced ||
            entry.healthKitLastWriteHash != entry.healthKitWriteHash
        }
    }

    private var healthKitPendingSyncCount: Int {
        entriesNeedingHealthKitSync.count
    }

    private func resetGeminiCostTotals() {
        if geminiCostAccumulators.isEmpty {
            GeminiCostAccumulator.current(in: modelContext).reset()
        } else {
            for accumulator in geminiCostAccumulators {
                accumulator.reset()
            }
        }
        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "gemini_cost_reset")
    }

    private var offContributionStatusText: String {
        guard offContributionSuccessCount > 0 else {
            return offContributeEnabled
                ? "Enabled, but no successful uploads have been recorded."
                : "Disabled. No successful uploads have been recorded."
        }

        let countText = offContributionSuccessCount == 1
            ? "1 successful upload"
            : "\(offContributionSuccessCount) successful uploads"

        guard offLastContributionAt > 0 else {
            return "\(countText) recorded."
        }

        let date = Date(timeIntervalSince1970: offLastContributionAt)
        return "\(countText). Last confirmed \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    private func performHealthKitBackfill() {
        Task {
            isSyncingHealthKit = true
            defer { isSyncingHealthKit = false }

            if !healthKit.isAuthorized {
                await healthKit.requestAuthorization()
            }

            guard healthKit.isAuthorized else {
                healthKitSyncResultMessage = "Apple Health authorization is required before OpenFoodJournal can sync nutrition samples."
                showHealthKitSyncResult = true
                return
            }

            let entries = entriesNeedingHealthKitSync
            let summary = await healthKit.syncMissingEntries(entries, in: modelContext)
            healthKitSyncResultMessage = summary.message
            showHealthKitSyncResult = true
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

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFoodJournal-Spreadsheet.csv")
        guard let _ = try? csv.write(to: tmpURL, atomically: true, encoding: .utf8) else { return }

        presentShareSheet(for: tmpURL)
    }

    // MARK: - Backup Export / Import

    private func presentGeminiLogExport() {
        let csv = GeminiScanLog.exportCSV(from: modelContext)
        guard !csv.isEmpty else {
            showNoGeminiLogsAlert = true
            return
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFoodJournal-Gemini-Logs.csv")
        guard let _ = try? csv.write(to: tmpURL, atomically: true, encoding: .utf8) else { return }

        presentShareSheet(for: tmpURL)
    }

    private func presentBackupExport() {
        do {
            let data = try nutritionStore.exportBackup(
                goals: goals,
                appSettings: AppSettingsRecord(
                    useProModel: useProModel,
                    offContributeEnabled: offContributeEnabled
                )
            )
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenFoodJournal-Backup.json")
            try data.write(to: tmpURL, options: .atomic)
            presentShareSheet(for: tmpURL)
        } catch {
            backupImportErrorMessage = error.localizedDescription
            showBackupImportError = true
        }
    }

    private func handleBackupImportSelection(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let isScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            pendingBackup = try OpenFoodJournalBackup.decoded(from: data)
            showBackupImportConfirmation = true
        } catch {
            backupImportErrorMessage = error.localizedDescription
            showBackupImportError = true
        }
    }

    private func performBackupImport() {
        guard let backup = pendingBackup else { return }
        defer { pendingBackup = nil }

        do {
            backupImportSummary = try nutritionStore.importBackup(backup, goals: goals)
            useProModel = backup.appSettings.useProModel
            offContributeEnabled = backup.appSettings.offContributeEnabled
            showBackupImportSuccess = true
        } catch {
            backupImportErrorMessage = error.localizedDescription
            showBackupImportError = true
        }
    }

    private func presentShareSheet(for url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }

        let activityVC = UIActivityViewController(
            activityItems: [url],  // sharing a URL gives the file a name + extension
            applicationActivities: nil
        )
        root.present(activityVC, animated: true)
    }
}

#Preview {
    let container = ModelContainer.preview
    SettingsView()
        .modelContainer(container)
        .environment(NutritionStore(modelContext: container.mainContext))
        .environment(HealthKitService())
        .environment(UserGoals())
}
