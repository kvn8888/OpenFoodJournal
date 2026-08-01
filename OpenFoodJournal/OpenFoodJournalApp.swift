// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

@main
struct MacrosApp: App {
    private let modelContainer: ModelContainer
    private let runtimeModelCatalog: RuntimeModelCatalog
    private let shouldRefreshRuntimeModelCatalog: Bool
    @State private var nutritionStore: NutritionStore
    @State private var scanService: ScanService
    @State private var tursoMirrorService: TursoMirrorService
    @State private var healthKitService: HealthKitService
    @State private var chatService: ChatService
    @State private var userGoals: UserGoals
    @State private var mealTimeSettings = MealTimeSettings()
    @State private var offService = OpenFoodFactsService()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(OFJAccentTheme.storageKey) private var accentThemeRawValue =
        OFJAccentTheme.defaultTheme.rawValue

    /// CloudKit container for this build configuration.
    ///
    /// Debug and Release name *different containers*, not the same container in
    /// different CloudKit environments. Environment routing is decided by code
    /// signing and is invisible in source; this is explicit and cannot drift.
    /// Must stay in sync with the `com.apple.developer.icloud-container-identifiers`
    /// entry in the matching entitlements file.
    // Internal so the Debug unit suite can enforce the runtime half of the
    // source-entitlements contract without launching CloudKit.
    static var cloudKitContainerIdentifier: String {
        #if DEBUG
        return "iCloud.k3vnc.OpenFoodJournal.dev"
        #else
        return "iCloud.k3vnc.OpenFoodJournal"
        #endif
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        let isUITest = environment["OFJ_UI_TEST_MODE"] == "1"
        let isTest = environment["XCTestConfigurationFilePath"] != nil || isUITest
        #if DEBUG
        if isUITest {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: "hasCompletedOnboarding")
            defaults.set(
                Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                forKey: "lastSeenVersion"
            )
            defaults.set(AssistantProvider.gemini.rawValue, forKey: AIProviderSettings.assistantProviderKey)
            defaults.set(ChatContextBudget.efficient.rawValue, forKey: AIProviderSettings.chatContextBudgetKey)
            defaults.set("https://uitest.openai.azure.com", forKey: AIProviderSettings.azureEndpointKey)
            defaults.set("ui-sol-deployment", forKey: AIProviderSettings.azureSolDeploymentKey)
            defaults.set("ui-terra-deployment", forKey: AIProviderSettings.azureTerraDeploymentKey)
        }
        #endif
        let config: ModelConfiguration
        if isTest {
            // Tests use in-memory store without CloudKit
            config = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            // Sync via CloudKit private database. Debug builds ship a separate
            // entitlements file naming a different container, so a developer
            // build can never read or write the production dataset. This is
            // declared here rather than inferred from the signing environment.
            config = ModelConfiguration(
                cloudKitDatabase: .private(Self.cloudKitContainerIdentifier)
            )
        }
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: NutritionEntry.self, DailyLog.self, SavedFood.self, TrackedContainer.self, Preferences.self, GeminiScanLog.self, GeminiCostAccumulator.self, ChatThread.self, ChatMessage.self, ChatAttachment.self, ChatContextCheckpoint.self, ChatSourceArtifact.self, ChatAgentRun.self, ChatWriteExecutionRecord.self, ChatDiagnosticSpan.self, ChatUsageDailyAggregate.self,
                configurations: config
            )
        } catch {
            #if DEBUG
            // A developer build whose CloudKit container is not provisioned yet
            // must not hard-crash at launch — that reads as a code bug. Fall
            // back to an in-memory store so the UI is still inspectable.
            print("[OFJ Dev] CloudKit ModelContainer unavailable, using in-memory store: \(error)")
            do {
                container = try ModelContainer(
                    for: NutritionEntry.self, DailyLog.self, SavedFood.self, TrackedContainer.self, Preferences.self, GeminiScanLog.self, GeminiCostAccumulator.self, ChatThread.self, ChatMessage.self, ChatAttachment.self, ChatContextCheckpoint.self, ChatSourceArtifact.self, ChatAgentRun.self, ChatWriteExecutionRecord.self, ChatDiagnosticSpan.self, ChatUsageDailyAggregate.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("Failed to create in-memory ModelContainer: \(error)")
            }
            #else
            fatalError("Failed to create ModelContainer: \(error)")
            #endif
        }
        modelContainer = container
        let modelCatalog = RuntimeModelCatalog()
        runtimeModelCatalog = modelCatalog
        shouldRefreshRuntimeModelCatalog = !isTest
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
            tursoMirror: tursoMirror,
            modelCatalog: isTest ? nil : modelCatalog
        ))
        let goals = UserGoals()
        _userGoals = State(initialValue: goals)
        #if DEBUG
        if isUITest {
            let thread = ChatThread(title: "Interrupted research")
            container.mainContext.insert(thread)
            let base = Date(timeIntervalSince1970: 1_700_200_000)
            for index in 0..<6 {
                let message = ChatMessage(
                    role: index.isMultiple(of: 2) ? .user : .model,
                    text: "Saved turn \(index + 1)",
                    timestamp: base.addingTimeInterval(Double(index))
                )
                message.thread = thread
                container.mainContext.insert(message)
                let attachment = ChatAttachment(
                    data: Data(repeating: 0x20, count: 60_000),
                    mimeType: "application/pdf",
                    filename: "context-\(index + 1).pdf"
                )
                attachment.message = message
                container.mainContext.insert(attachment)
                message.attachments?.append(attachment)
                thread.messages?.append(message)
            }
            let interrupted = ChatAgentRun(providerID: "gemini", modelID: "ui-test")
            interrupted.thread = thread
            container.mainContext.insert(interrupted)
            thread.agentRuns?.append(interrupted)
            try? container.mainContext.save()

            _chatService = State(initialValue: ChatService(
                modelContext: container.mainContext,
                nutritionStore: store,
                userGoals: goals,
                healthKitService: health,
                tursoMirror: tursoMirror,
                modelProxyFactory: { selection in
                    AssistantUITestModelProxy(descriptor: selection.descriptor)
                },
                apiKeyProvider: { _ in "ui-test-key" },
                modelCatalog: nil
            ))
        } else {
            _chatService = State(initialValue: ChatService(
                modelContext: container.mainContext,
                nutritionStore: store,
                userGoals: goals,
                healthKitService: health,
                tursoMirror: tursoMirror,
                modelCatalog: modelCatalog
            ))
        }
        #else
        _chatService = State(initialValue: ChatService(
            modelContext: container.mainContext,
            nutritionStore: store,
            userGoals: goals,
            healthKitService: health,
            tursoMirror: tursoMirror,
            modelCatalog: modelCatalog
        ))
        #endif

        // Ensure the Preferences singleton exists in SwiftData
        _ = Preferences.current(in: container.mainContext)
        _ = GeminiCostAccumulator.current(in: container.mainContext)
        let expiredAILogCount = GeminiScanLog.pruneExpired(in: container.mainContext)
        let expiredAssistantSpanCount = ChatDiagnosticSpan.pruneExpired(in: container.mainContext)
        if expiredAILogCount + expiredAssistantSpanCount > 0 {
            // These model types remain only as a compatibility shell while
            // older CloudKit-backed rows migrate to append-only Turso events.
            try? container.mainContext.save()
        }
    }

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasRetrolinkedMappings") private var hasRetrolinkedMappings = false

    private var accentTheme: OFJAccentTheme {
        OFJAccentTheme.resolved(from: accentThemeRawValue)
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
                    .cursorAtEnd()
                    .tint(accentTheme.accentColor)
                    .environment(\.ofjAccentTheme, accentTheme)
                    .modelContainer(modelContainer)
                    .environment(nutritionStore)
                    .environment(scanService)
                    .environment(chatService)
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
                        await tursoMirrorService.migrateLegacyDiagnostics()
                        if shouldRefreshRuntimeModelCatalog {
                            _ = await runtimeModelCatalog.refreshIfNeeded()
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            tursoMirrorService.scheduleMirror(reason: "app_foreground")
                            Task {
                                await reconcilePendingHealthKitEntries()
                                await tursoMirrorService.migrateLegacyDiagnostics()
                                _ = await tursoMirrorService.flushDiagnosticOutbox()
                                if shouldRefreshRuntimeModelCatalog {
                                    _ = await runtimeModelCatalog.refreshIfNeeded()
                                }
                            }
                        } else if phase == .background {
                            chatService.suspendForBackgrounding()
                        }
                    }
            } else {
                OnboardingView()
                    .tint(accentTheme.accentColor)
                    .environment(\.ofjAccentTheme, accentTheme)
                    .modelContainer(modelContainer)
                    .environment(nutritionStore)
                    .environment(scanService)
                    .environment(chatService)
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
