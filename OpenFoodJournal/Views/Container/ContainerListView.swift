// OpenFoodJournal — ContainerListView
// Shows all tracked containers (active and completed).
// Active containers show "Enter Final Weight" action.
// Completed containers show the consumed nutrition summary.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct ContainerListView: View {
    // ── SwiftData Queries ─────────────────────────────────────────
    // Active containers sorted by most recently started
    @Query(
        filter: #Predicate<TrackedContainer> { $0.finalWeight == nil },
        sort: \TrackedContainer.startDate,
        order: .reverse
    )
    private var activeContainers: [TrackedContainer]

    // Completed containers sorted by completion date
    @Query(
        filter: #Predicate<TrackedContainer> { $0.finalWeight != nil },
        sort: \TrackedContainer.completedDate,
        order: .reverse
    )
    private var completedContainers: [TrackedContainer]

    // ── Environment ───────────────────────────────────────────────
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore

    /// Date to log completed container nutrition to
    var logDate: Date = .now

    // ── State ─────────────────────────────────────────────────────
    @State private var containerToComplete: TrackedContainer?  // Sheet for entering final weight
    @State private var showNewContainer = false                 // Sheet for creating new container

    var body: some View {
        NavigationStack {
            Group {
                if activeContainers.isEmpty && completedContainers.isEmpty {
                    emptyState
                } else {
                    containerList
                }
            }
            .navigationTitle("Containers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewContainer = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $containerToComplete) { container in
                CompleteContainerSheet(container: container, logDate: logDate)
            }
            .sheet(isPresented: $showNewContainer) {
                NewContainerSheet()
            }
        }
    }

    // MARK: - Container List

    private var containerList: some View {
        List {
            // Active containers section
            if !activeContainers.isEmpty {
                Section("Active") {
                    ForEach(activeContainers) { container in
                        ActiveContainerRow(container: container) {
                            containerToComplete = container
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let id = activeContainers[index].id
                            modelContext.delete(activeContainers[index])
                        }
                        try? modelContext.save()
                    }
                }
            }

            // Completed containers section
            if !completedContainers.isEmpty {
                Section("Completed") {
                    ForEach(completedContainers) { container in
                        CompletedContainerRow(container: container)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let id = completedContainers[index].id
                            modelContext.delete(completedContainers[index])
                        }
                        try? modelContext.save()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tracked Containers", systemImage: "scalemass")
        } description: {
            Text("Track a food container to measure consumption by weight over time.")
        } actions: {
            Button("Start Tracking") {
                showNewContainer = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Active Container Row

/// Shows an active container with its food name, start weight, and days tracked.
/// Tap "Weigh" to enter the final weight and complete tracking.
private struct ActiveContainerRow: View {
    let container: TrackedContainer
    let onComplete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Food name + optional brand
                Text(container.foodName)
                    .font(.body)
                    .fontWeight(.medium)

                if let brand = container.foodBrand {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Start weight and days tracking
                HStack(spacing: 8) {
                    Label("\(Int(container.startWeight))g", systemImage: "scalemass")
                    Text("·")
                    Text(daysTracked)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // "Weigh" button to enter final weight
            Button("Weigh", action: onComplete)
                .buttonStyle(.bordered)
                .tint(.blue)
        }
        .padding(.vertical, 4)
    }

    /// How many days this container has been tracked
    private var daysTracked: String {
        let days = Calendar.current.dateComponents([.day], from: container.startDate, to: .now).day ?? 0
        return days == 0 ? "Started today" : "\(days) day\(days == 1 ? "" : "s")"
    }
}

// MARK: - Completed Container Row

/// Shows a completed container with consumed nutrition summary.
private struct CompletedContainerRow: View {
    let container: TrackedContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Food name
            Text(container.foodName)
                .font(.body)
                .fontWeight(.medium)

            // Consumed weight
            if let grams = container.consumedGrams {
                Text("Consumed \(Int(grams))g")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Macro summary
            if let cals = container.consumedCalories {
                HStack(spacing: 12) {
                    MacroPill(label: "Cal", value: cals, color: .orange)
                    MacroPill(label: "P", value: container.consumedProtein ?? 0, color: .blue)
                    MacroPill(label: "C", value: container.consumedCarbs ?? 0, color: .green)
                    MacroPill(label: "F", value: container.consumedFat ?? 0, color: .yellow)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A small colored pill showing a macro value
private struct MacroPill: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        Text("\(label) \(Int(value))")
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }
}
