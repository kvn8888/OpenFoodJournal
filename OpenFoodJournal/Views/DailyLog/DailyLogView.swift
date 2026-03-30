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
    // Captures the selected date when the user opens the scan camera,
    // so the result is logged to the correct day even if the calendar changes.
    @State private var scanDate: Date = .now

    private var log: DailyLog? {
        nutritionStore.fetchLog(for: selectedDate)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Replaced ScrollView+LazyVStack with List so that .swipeActions on
                // EntryRowView and MealSectionView actually fire — swipeActions is a
                // List-only modifier in SwiftUI and is silently ignored in a LazyVStack.
                List {
                    // Calendar strip — clear background, no separator, matches original padding
                    WeeklyCalendarStrip(selectedDate: $selectedDate)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))

                    // Macro summary card — tap to view full nutrition details
                    MacroSummaryBar(log: log, goals: goals)
                        .background {
                            NavigationLink("", destination: NutritionDetailView())
                                .opacity(0)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    // Meal sections — MealSectionView returns a Section{} so each
                    // meal type becomes a sticky List section with its header
                    if let log, !log.safeEntries.isEmpty {
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
                    } else {
                        EmptyLogView()
                            .padding(.top, 40)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowInsets(EdgeInsets())
                    }

                    // Spacer so the last entry is never hidden behind the radial FAB
                    Color.clear
                        .frame(height: 100)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
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
                        action: {
                            scanDate = selectedDate
                            presentedSheet = .scan
                        }
                    ),
                ])
            }
            .navigationTitle("Journal")
            .navigationBarTitleDisplayMode(.large)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .scan:
                ScanCaptureView(logDate: selectedDate)
            case .manualEntry:
                ManualEntryView(defaultDate: selectedDate)
            case .editEntry(let entry):
                EditEntryView(entry: entry)
            case .foodBank:
                FoodBankView(logDate: selectedDate)
            case .containers:
                ContainerListView(logDate: selectedDate)
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
                ScanResultSheet(entry: entry, logDate: scanDate)
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
/// Handles log-only, log+save, and retake actions.
private struct ScanResultSheet: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(ScanService.self) private var scanService
    @Environment(\.dismiss) private var dismiss

    @Bindable var entry: NutritionEntry
    let logDate: Date

    var body: some View {
        ScanResultCard(
            entry: entry,
            onConfirm: {
                // Log entry only — no Food Bank save
                nutritionStore.log(entry, to: logDate)
                scanService.pendingResult = nil
                dismiss()
            },
            onConfirmAndSave: {
                // Log entry to journal
                nutritionStore.log(entry, to: logDate)

                // Also save to Food Bank
                let saved = SavedFood(from: entry)
                nutritionStore.modelContext.insert(saved)
                try? nutritionStore.modelContext.save()

                scanService.pendingResult = nil
                dismiss()
            },
            onRetake: {
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
