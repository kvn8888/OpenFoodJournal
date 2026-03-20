// OpenFoodJournal — FoodBankView
// Main view for the Personal Food Bank tab.
// Shows a searchable, sortable list of all saved foods.
// Users can tap a food to log it to today's journal or swipe to delete.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct FoodBankView: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(SyncService.self) private var syncService

    // ── SwiftData Query: fetches all SavedFood sorted by most recently created ──
    @Query(sort: \SavedFood.createdAt, order: .reverse)
    private var allFoods: [SavedFood]

    // ── Local State ───────────────────────────────────────────────
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .newest
    @State private var selectedFood: SavedFood?       // For the "log it" sheet
    @State private var showDeleteConfirm = false
    @State private var foodToDelete: SavedFood?

    // ── Computed: filter + sort the foods based on search text ────
    // Filters by name (case-insensitive) so users can quickly find a food
    private var filteredFoods: [SavedFood] {
        let filtered = searchText.isEmpty
            ? allFoods
            : allFoods.filter { $0.name.localizedCaseInsensitiveContains(searchText) }

        switch sortOrder {
        case .newest:
            return filtered  // Already sorted by createdAt desc from @Query
        case .alphabetical:
            return filtered.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .calories:
            return filtered.sorted { $0.calories > $1.calories }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allFoods.isEmpty {
                    // ── Empty state: no saved foods yet ──
                    emptyState
                } else {
                    // ── Food list with search ──
                    foodList
                }
            }
            .navigationTitle("Food Bank")
            .searchable(text: $searchText, prompt: "Search saved foods")
            .toolbar {
                // Sort picker in the toolbar
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            // Sheet to log a selected food to today's journal
            .sheet(item: $selectedFood) { food in
                LogFoodSheet(food: food)
            }
        }
    }

    // MARK: - Food List

    /// The main scrollable list of saved foods, grouped by search results.
    /// Each row is tappable (to log) and swipeable (to delete).
    private var foodList: some View {
        List {
            // Show result count when searching
            if !searchText.isEmpty {
                Text("\(filteredFoods.count) result\(filteredFoods.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            ForEach(filteredFoods) { food in
                // Tap a row to open the "Log this food" sheet
                Button {
                    selectedFood = food
                } label: {
                    SavedFoodRowView(food: food)
                }
                .tint(.primary)  // Keep text colors normal (not blue link style)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        let foodId = food.id
                        modelContext.delete(food)
                        try? modelContext.save()
                        Task { try? await syncService.deleteFood(id: foodId) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Empty State

    /// Shown when the food bank has no saved foods yet.
    /// Guides the user on how to save foods from scans or manual entries.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Saved Foods", systemImage: "refrigerator")
        } description: {
            Text("Foods you save from scans or manual entries will appear here for quick re-logging.")
        }
    }

    // MARK: - Sort Menu

    /// Toolbar menu for changing the sort order of the food list.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Label(order.label, systemImage: order.icon)
                        .tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

// MARK: - Sort Order

/// Controls how saved foods are ordered in the list.
/// Each case has a user-friendly label and an SF Symbol icon.
enum SortOrder: String, CaseIterable, Identifiable {
    case newest
    case alphabetical
    case calories

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: "Newest First"
        case .alphabetical: "A → Z"
        case .calories: "Highest Calories"
        }
    }

    var icon: String {
        switch self {
        case .newest: "clock"
        case .alphabetical: "textformat.abc"
        case .calories: "flame"
        }
    }
}
