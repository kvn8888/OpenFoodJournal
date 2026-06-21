// OpenFoodJournal — Turso Integration Settings
// AGPL-3.0 License

import SwiftData
import SwiftUI

struct TursoIntegrationSettingsView: View {
    @Environment(TursoMirrorService.self) private var tursoMirror

    @AppStorage(TursoMirrorService.enabledKey) private var tursoEnabled: Bool = false
    @AppStorage(TursoMirrorService.includeDiagnosticsKey) private var includeDiagnostics: Bool = true
    @AppStorage(TursoMirrorService.lastSyncAtKey) private var lastSyncAtTimestamp: Double = 0
    @AppStorage(TursoMirrorService.lastErrorKey) private var lastError: String = ""
    @AppStorage(TursoMirrorService.lastRowCountKey) private var lastRowCount: Int = 0

    @State private var databaseURLInput = ""
    @State private var authTokenInput = ""
    @State private var hasCredentials = false
    @State private var statusMessage: String?
    @State private var busyAction: BusyAction?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { tursoEnabled },
                    set: setMirrorEnabled
                )) {
                    Label("Mirror Data to Turso", systemImage: "externaldrive.badge.icloud")
                }

                TextField("libsql://your-db.turso.io", text: $databaseURLInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("Turso database auth token", text: $authTokenInput)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button {
                        saveCredentials()
                    } label: {
                        Label("Save Credentials", systemImage: "key")
                    }
                    .disabled(databaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    Button(role: .destructive) {
                        removeCredentials()
                    } label: {
                        Label("Remove Credentials", systemImage: "trash")
                    }
                    .disabled(!hasCredentials)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Use a database URL from Turso and a database auth token. libsql:// URLs are normalized to HTTPS internally for SQL-over-HTTP.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { includeDiagnostics },
                    set: setIncludeDiagnostics
                )) {
                    Label("Include Diagnostics", systemImage: "stethoscope")
                }

                Button {
                    run(.testConnection)
                } label: {
                    actionLabel("Test Connection", systemImage: "checkmark.seal", action: .testConnection)
                }
                .disabled(!hasCredentials || busyAction != nil)

                Button {
                    run(.runMigrations)
                } label: {
                    actionLabel("Run Migrations", systemImage: "tablecells.badge.ellipsis", action: .runMigrations)
                }
                .disabled(!hasCredentials || busyAction != nil)

                Button {
                    run(.syncNow)
                } label: {
                    actionLabel("Sync Now", systemImage: "arrow.triangle.2.circlepath", action: .syncNow)
                }
                .disabled(!hasCredentials || !tursoEnabled || busyAction != nil)
            } header: {
                Text("Mirror")
            } footer: {
                Text("OpenFoodJournal remains the source of truth. Turso is a push-only external mirror for your own SQL inspection and debugging.")
            }

            Section {
                LabeledContent("Enabled", value: tursoEnabled ? "Yes" : "No")
                LabeledContent("Credentials", value: hasCredentials ? "Saved" : "Missing")
                LabeledContent("Last Successful Mirror", value: lastSyncText)
                LabeledContent("Mirrored Rows", value: lastRowCount.formatted())

                if !lastError.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Last Failure", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            }
        }
        .navigationTitle("Turso Integration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadCredentialsState)
    }

    private var lastSyncText: String {
        guard lastSyncAtTimestamp > 0 else { return "Never" }
        let date = Date(timeIntervalSince1970: lastSyncAtTimestamp)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func actionLabel(_ title: String, systemImage: String, action: BusyAction) -> some View {
        Label {
            Text(busyAction == action ? action.busyTitle : title)
        } icon: {
            if busyAction == action {
                ProgressView()
            } else {
                Image(systemName: systemImage)
            }
        }
    }

    private func loadCredentialsState() {
        hasCredentials = KeychainService.hasTursoCredentials
        databaseURLInput = KeychainService.tursoDatabaseURL ?? ""
        authTokenInput = KeychainService.tursoAuthToken.map { _ in "" } ?? ""
    }

    private func saveCredentials() {
        guard let normalizedURL = TursoMirrorService.normalizedHTTPURLString(databaseURLInput) else {
            statusMessage = "Enter a valid libsql:// or https:// Turso database URL."
            return
        }

        let token = authTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "Enter a Turso auth token."
            return
        }

        let savedURL = KeychainService.save(normalizedURL, for: KeychainService.tursoDatabaseURLAccount)
        let savedToken = KeychainService.save(token, for: KeychainService.tursoAuthTokenAccount)

        hasCredentials = savedURL && savedToken
        databaseURLInput = normalizedURL
        authTokenInput = ""
        statusMessage = hasCredentials ? "Credentials saved." : "Credentials could not be saved."
    }

    private func removeCredentials() {
        KeychainService.delete(for: KeychainService.tursoDatabaseURLAccount)
        KeychainService.delete(for: KeychainService.tursoAuthTokenAccount)
        tursoMirror.setEnabled(false)
        hasCredentials = false
        databaseURLInput = ""
        authTokenInput = ""
        statusMessage = "Turso credentials removed."
    }

    private func setMirrorEnabled(_ enabled: Bool) {
        guard !enabled || hasCredentials else {
            statusMessage = "Save Turso credentials before enabling mirroring."
            tursoEnabled = false
            return
        }
        tursoMirror.setEnabled(enabled)
        statusMessage = enabled ? "Mirroring enabled. Use Sync Now for the first full mirror." : "Mirroring disabled."
    }

    private func setIncludeDiagnostics(_ include: Bool) {
        tursoMirror.setIncludeDiagnostics(include)
        statusMessage = include
            ? "Gemini logs and cost counters will be mirrored."
            : "Gemini diagnostic tables will be cleared on the next mirror."
    }

    private func run(_ action: BusyAction) {
        Task {
            busyAction = action
            statusMessage = nil
            defer { busyAction = nil }

            do {
                switch action {
                case .testConnection:
                    try await tursoMirror.testConnection()
                    statusMessage = "Connection succeeded."
                case .runMigrations:
                    try await tursoMirror.runMigrations()
                    statusMessage = "Migrations completed."
                case .syncNow:
                    try await tursoMirror.runMigrations()
                    await tursoMirror.mirrorAll(reason: "settings_sync_now")
                    statusMessage = tursoMirror.lastError == nil
                        ? "Mirror completed."
                        : "Mirror finished with an error. Check status below."
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private enum BusyAction: Equatable {
        case testConnection
        case runMigrations
        case syncNow

        var busyTitle: String {
            switch self {
            case .testConnection: "Testing Connection"
            case .runMigrations: "Running Migrations"
            case .syncNow: "Syncing"
            }
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: NutritionEntry.self, DailyLog.self, SavedFood.self, TrackedContainer.self, Preferences.self, GeminiScanLog.self, GeminiCostAccumulator.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    NavigationStack {
        TursoIntegrationSettingsView()
            .environment(TursoMirrorService(modelContext: container.mainContext))
    }
}
