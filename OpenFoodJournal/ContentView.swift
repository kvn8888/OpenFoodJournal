// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var userGoals
    @Environment(ChatService.self) private var chatService

    // Tracks the last version the user saw What's New for.
    // When the app version changes, the sheet is shown again.
    @AppStorage("lastSeenVersion") private var lastSeenVersion: String = ""
    @State private var showWhatsNew = false
    @State private var selectedTab: AppTab = .journal

    private enum AppTab: Hashable {
        case journal, foodBank, history, assistant, settings
    }

    /// The current app version from Info.plist (e.g. "1.1")
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Journal", systemImage: "book.pages", value: .journal) {
                DailyLogView()
            }
            Tab("Food Bank", systemImage: "refrigerator", value: .foodBank) {
                FoodBankView()
            }
            Tab("History", systemImage: "chart.xyaxis.line", value: .history) {
                HistoryView()
            }
            Tab("Assistant", systemImage: chatService.isStreaming ? "sparkles.square.filled.on.square" : "sparkles", value: .assistant) {
                ChatView()
            }
            .badge(chatService.isStreaming ? Text("Active") : nil)
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.never)
        .safeAreaInset(edge: .top, spacing: 0) {
            if chatService.isStreaming && selectedTab != .assistant {
                globalAssistantBanner
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
        }
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

    private var globalAssistantBanner: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = max(0, Int(timeline.date.timeIntervalSince(chatService.activeStartedAt ?? timeline.date)))
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(globalAssistantStatus)
                        .font(.caption.weight(.semibold))
                    Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { selectedTab = .assistant }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open active Assistant conversation")
                Button {
                    chatService.cancelCurrentRun()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Stop Assistant")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(.regular.tint(.blue.opacity(0.10)), in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("assistant.global-banner")
        }
    }

    private var globalAssistantStatus: String {
        switch chatService.activePhase ?? .queued {
        case .queued, .preparing: "Assistant · Preparing…"
        case .waitingForProvider: "Assistant · Waiting for \(chatService.activeProviderName ?? "provider")…"
        case .executingTools: "Assistant · Running tools…"
        case .awaitingApproval: "Assistant · Approval needed"
        case .finalizing: "Assistant · Finalizing…"
        case .suspended: "Assistant · Suspended"
        case .completed: "Assistant · Completed"
        case .failed: "Assistant · Failed"
        case .cancelled: "Assistant · Cancelled"
        }
    }
}

#Preview {
    let container = ModelContainer.preview
    let store = NutritionStore(modelContext: container.mainContext)
    let goals = UserGoals()
    let health = HealthKitService()
    ContentView()
        .modelContainer(container)
        .environment(store)
        .environment(ScanService())
        .environment(health)
        .environment(goals)
        .environment(MealTimeSettings())
        .environment(ChatService(
            modelContext: container.mainContext,
            nutritionStore: store,
            userGoals: goals,
            healthKitService: health
        ))
}
