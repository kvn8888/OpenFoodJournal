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

    /// Date to log foods to (passed from DailyLogView when opened via radial menu)
    var logDate: Date = .now

    // ── SwiftData Query: fetches all SavedFood sorted by most recently created ──
    @Query(sort: \SavedFood.createdAt, order: .reverse)
    private var allFoods: [SavedFood]

    // ── Local State ───────────────────────────────────────────────
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .newest
    @State private var selectedFood: SavedFood?       // For the "log it" sheet
    @State private var foodToEdit: SavedFood?          // For the edit sheet
    @State private var showDeleteConfirm = false
    @State private var foodToDelete: SavedFood?

    // Cached, stable array for the ForEach — updated only when allFoods, searchText,
    // or sortOrder actually change. Avoids new-array-identity on every body evaluation,
    // which would force a full ForEach re-diff and can stutter mid-swipe if a background
    // @Query update fires during gesture tracking.
    @State private var displayedFoods: [SavedFood] = []

    private func applyFilter() -> [SavedFood] {
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
            // Recompute only when the underlying data or user inputs actually change,
            // not on every body evaluation — keeps the ForEach identity stable during swipes.
            .onAppear { displayedFoods = applyFilter() }
            .onChange(of: allFoods) { displayedFoods = applyFilter() }
            .onChange(of: searchText) { displayedFoods = applyFilter() }
            .onChange(of: sortOrder) { displayedFoods = applyFilter() }
            .toolbar {
                // Sort picker in the toolbar
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            // Sheet to log a selected food to the selected day's journal
            .sheet(item: $selectedFood) { food in
                LogFoodSheet(food: food, logDate: logDate)
            }
            // Sheet to edit a food's name, brand, macros
            .sheet(item: $foodToEdit) { food in
                EditFoodSheet(food: food)
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
                Text("\(displayedFoods.count) result\(displayedFoods.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            ForEach(displayedFoods) { food in
                // Wrap in a Button + .buttonStyle(.plain) — the same pattern that
                // makes DailyLogView swipes silky smooth.
                //
                // Previous approach used .onTapGesture + .contentShape(Rectangle()),
                // which eliminated the initial-tap delay but made the *swipe* gesture
                // choppy because TapGesture and the List's swipe recognizer competed.
                //
                // Button with .buttonStyle(.plain) is optimised by UIKit for coexistence
                // with List swipe actions — the system knows to hand off to the swipe
                // recognizer early without waiting for a full tap-disambiguation pass.
                Button {
                    selectedFood = food
                } label: {
                    SavedFoodRowView(food: food)
                }
                .buttonStyle(.plain)
                // Trailing swipe (left) — Edit is the first/light action, Delete requires more swipe
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Edit: opens the name/brand/macro editor
                    Button {
                        foodToEdit = food
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                    // Delete: destructive second action (deeper swipe required)
                    Button(role: .destructive) {
                        let foodId = food.id
                        modelContext.delete(food)
                        try? modelContext.save()
                        Task { try? await syncService.deleteFood(id: foodId) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                // Leading swipe (right) — quick-add shortcut opens the same LogFoodSheet as tapping
                .swipeActions(edge: .leading) {
                    Button {
                        selectedFood = food
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .tint(.green)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
