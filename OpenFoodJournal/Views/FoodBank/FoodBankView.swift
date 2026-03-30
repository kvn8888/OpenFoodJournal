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

    /// Date to log foods to (passed from DailyLogView when opened via radial menu)
    var logDate: Date = .now

    // ── SwiftData Query: fetches all SavedFood sorted by most recently created ──
    @Query(sort: \SavedFood.createdAt, order: .reverse)
    private var allFoods: [SavedFood]

    // ── Local State ───────────────────────────────────────────────
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .lastUsed
    @State private var selectedFood: SavedFood?       // For the "log it" sheet
    @State private var foodToEdit: SavedFood?          // For the edit sheet

    // ── Computed: filter + sort the foods based on search text ────
    // Filters by name and brand (case-insensitive) so users can quickly find a food.
    // Safe to compute here because the result is never held in @State — SwiftData
    // @Model objects must stay owned by the ModelContext, not captured in @State.
    private var filteredFoods: [SavedFood] {
        let filtered = searchText.isEmpty
            ? allFoods
            : allFoods.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.brand?.localizedCaseInsensitiveContains(searchText) ?? false)
            }

        switch sortOrder {
        case .lastUsed:
            return filtered.sorted { $0.lastUsedAt > $1.lastUsedAt }
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
                Text("\(filteredFoods.count) result\(filteredFoods.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            ForEach(filteredFoods) { food in
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
                // Trailing swipe (left) — Edit only; delete lives inside EditFoodSheet
                .swipeActions(edge: .trailing) {
                    Button {
                        foodToEdit = food
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
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
    case lastUsed
    case newest
    case alphabetical
    case calories

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastUsed: "Last Used"
        case .newest: "Newest First"
        case .alphabetical: "A → Z"
        case .calories: "Highest Calories"
        }
    }

    var icon: String {
        switch self {
        case .lastUsed: "clock.arrow.circlepath"
        case .newest: "clock"
        case .alphabetical: "textformat.abc"
        case .calories: "flame"
        }
    }
}
