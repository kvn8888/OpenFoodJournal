// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct DailyLogView: View {
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(UserGoals.self) private var goals

    @State private var selectedDate: Date = .now
    @State private var presentedSheet: DailyLogSheet?
    @State private var selectedEntry: NutritionEntry?
    @Namespace private var namespace

    private var log: DailyLog? {
        nutritionStore.fetchLog(for: selectedDate)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 16) {
                        // Date selector
                        DateSelectorView(selectedDate: $selectedDate)
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

                // Floating scan button
                FloatingScanButton(namespace: namespace) {
                    presentedSheet = .scan
                } onManual: {
                    presentedSheet = .manualEntry
                }
                .padding(.bottom, 16)
            }
            .navigationTitle("Journal")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
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
            }
        }
    }
}

// MARK: - Sheet Enum

enum DailyLogSheet: Identifiable {
    case scan
    case manualEntry
    case editEntry(NutritionEntry)

    var id: String {
        switch self {
        case .scan: "scan"
        case .manualEntry: "manualEntry"
        case .editEntry(let e): "edit-\(e.id)"
        }
    }
}

// MARK: - Date Selector

private struct DateSelectorView: View {
    @Binding var selectedDate: Date

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)

            Spacer()

            VStack(spacing: 1) {
                Text(selectedDate, style: .date)
                    .font(.headline)
                    .fontWeight(.semibold)
                if Calendar.current.isDateInToday(selectedDate) {
                    Text("Today")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if Calendar.current.isDateInYesterday(selectedDate) {
                    Text("Yesterday")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .onTapGesture {
                withAnimation(.spring(duration: 0.3)) {
                    selectedDate = .now
                }
            }

            Spacer()

            Button {
                withAnimation(.spring(duration: 0.3)) {
                    let next = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                    if next <= .now {
                        selectedDate = next
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .opacity(Calendar.current.isDateInToday(selectedDate) ? 0.3 : 1)
            .disabled(Calendar.current.isDateInToday(selectedDate))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(in: .rect(cornerRadius: 14))
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
            Text("Tap the scan button below to log your first meal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Floating Scan Button

private struct FloatingScanButton: View {
    var namespace: Namespace.ID
    let onScan: () -> Void
    let onManual: () -> Void

    @State private var isExpanded = false

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if isExpanded {
                    Button {
                        isExpanded = false
                        onManual()
                    } label: {
                        Label("Manual", systemImage: "pencil")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.glass)
                    .glassEffectID("manual", in: namespace)
                    .transition(.scale.combined(with: .opacity))
                }

                // Primary scan button
                Button {
                    if isExpanded {
                        isExpanded = false
                        onScan()
                    } else {
                        withAnimation(.spring(duration: 0.4)) {
                            isExpanded = true
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "camera.fill" : "camera.viewfinder")
                            .font(.system(size: 20, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                        if !isExpanded {
                            Text("Scan")
                                .font(.headline)
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, isExpanded ? 16 : 24)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.glassProminent)
                .glassEffectID("scan", in: namespace)
            }
        }
        .padding(.horizontal, 24)
        .onTapGesture {} // Absorb taps outside
        .contentShape(Rectangle())
        // Collapse on tap elsewhere — handled by background tap
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
