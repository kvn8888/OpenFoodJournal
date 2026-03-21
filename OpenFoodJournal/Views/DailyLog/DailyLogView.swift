// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct DailyLogView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(ScanService.self) private var scanService
    @Environment(UserGoals.self) private var goals

    @State private var selectedDate: Date = .now
    @State private var presentedSheet: DailyLogSheet?
    @State private var selectedEntry: NutritionEntry?

    private var log: DailyLog? {
        nutritionStore.fetchLog(for: selectedDate)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 16) {
                        // Weekly calendar strip — shows 7 days with state-driven styling
                        WeeklyCalendarStrip(selectedDate: $selectedDate)
                            .padding(.horizontal)

                        // Macro summary card
                        MacroSummaryBar(log: log, goals: goals)
                            .padding(.horizontal)

                        // Meal sections
                        if let log, !log.entries.isEmpty {
                            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(MealType.allCases) { mealType in
                                    MealSectionView(
                                        mealType: mealType,
                                        entries: log.entries(for: mealType),
                                        onSelect: { entry in
                                            selectedEntry = entry
                                            presentedSheet = .editEntry(entry)
                                        },
                                        onDelete: { entry in
                                            nutritionStore.delete(entry)
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal)
                        } else {
                            EmptyLogView()
                                .padding(.top, 40)
                        }

                        // Bottom padding for FAB
                        Color.clear.frame(height: 100)
                    }
                    .padding(.top, 8)
                }
                .scrollContentBackground(.hidden)

                // Radial floating action menu — plus button with drag-to-action options
                RadialMenuButton(items: [
                    RadialMenuItem(
                        id: "foodbank",
                        label: "Food Bank",
                        icon: "refrigerator",
                        color: .purple,
                        action: { presentedSheet = .foodBank }
                    ),
                    RadialMenuItem(
                        id: "containers",
                        label: "Containers",
                        icon: "scalemass",
                        color: .orange,
                        action: { presentedSheet = .containers }
                    ),
                    RadialMenuItem(
                        id: "manual",
                        label: "Manual",
                        icon: "pencil",
                        color: .green,
                        action: { presentedSheet = .manualEntry }
                    ),
                    RadialMenuItem(
                        id: "scan",
                        label: "Scan",
                        icon: "camera.fill",
                        color: .blue,
                        action: { presentedSheet = .scan }
                    ),
                ])
            }
            .navigationTitle("Journal")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        MicronutrientSummaryView()
                    } label: {
                        Image(systemName: "list.bullet.clipboard")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(selectedDate, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .scan:
                ScanCaptureView()
            case .manualEntry:
                ManualEntryView(defaultDate: selectedDate)
            case .editEntry(let entry):
                EditEntryView(entry: entry)
            case .foodBank:
                FoodBankView()
            case .containers:
                ContainerListView()
            }
        }
        // Processing overlay — shown after camera dismisses while Gemini analyzes
        .overlay {
            if scanService.isScanning {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Analyzing…")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .padding(32)
                    .glassEffect(in: .rect(cornerRadius: 20))
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: scanService.isScanning)
            }
        }
        // When scan completes, show result card as a sheet
        .sheet(isPresented: Binding(
            get: { scanService.pendingResult != nil },
            set: { if !$0 { scanService.pendingResult = nil } }
        )) {
            if let entry = scanService.pendingResult {
                ScanResultSheet(entry: entry)
            }
        }
    }
}

// MARK: - Sheet Enum

enum DailyLogSheet: Identifiable {
    case scan
    case manualEntry
    case editEntry(NutritionEntry)
    case foodBank
    case containers

    var id: String {
        switch self {
        case .scan: "scan"
        case .manualEntry: "manualEntry"
        case .editEntry(let e): "edit-\(e.id)"
        case .foodBank: "foodBank"
        case .containers: "containers"
        }
    }
}

// MARK: - Scan Result Sheet

/// Wraps ScanResultCard in a sheet presented after background scanning completes.
/// Handles confirm (log + auto-save to Food Bank) and retake (re-open camera).
private struct ScanResultSheet: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(ScanService.self) private var scanService
    @Environment(\.dismiss) private var dismiss

    @Bindable var entry: NutritionEntry

    var body: some View {
        ScanResultCard(
            entry: entry,
            onConfirm: {
                // Log entry to today's journal
                nutritionStore.log(entry, to: .now)

                // Auto-save to Food Bank
                let saved = SavedFood(from: entry)
                nutritionStore.modelContext.insert(saved)
                try? nutritionStore.modelContext.save()
                let sync = nutritionStore.syncService
                Task { try? await sync?.createFood(saved) }

                // Clear pending result and dismiss
                scanService.pendingResult = nil
                dismiss()
            },
            onRetake: {
                // Clear result and dismiss — user can re-open camera from FAB
                scanService.pendingResult = nil
                dismiss()
            }
        )
    }
}

// MARK: - Empty State

private struct EmptyLogView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "fork.knife.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No meals logged")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Tap + below to log your first meal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

#Preview("With Entries") {
    let container = ModelContainer.preview
    let store = NutritionStore(modelContext: container.mainContext)
    DailyLogView()
        .modelContainer(container)
        .environment(store)
        .environment(UserGoals())
}

#Preview("Empty") {
    let schema = Schema([NutritionEntry.self, DailyLog.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    let store = NutritionStore(modelContext: container.mainContext)
    DailyLogView()
        .modelContainer(container)
        .environment(store)
        .environment(UserGoals())
}
