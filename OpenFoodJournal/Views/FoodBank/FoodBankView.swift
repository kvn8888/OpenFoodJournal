// OpenFoodJournal — FoodBankView
// Main view for the Personal Food Bank tab.
// Shows a searchable, sortable list of active saved foods.
// Users can tap a food to log it to today's journal or swipe to edit/archive.
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct FoodBankView: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(TursoMirrorService.self) private var tursoMirror

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
    @State private var addSheet: FoodBankAddSheet?

    // ── Computed: filter + sort the foods based on search text ────
    // Filters by name and brand (case-insensitive) so users can quickly find a food.
    // Safe to compute here because the result is never held in @State — SwiftData
    // @Model objects must stay owned by the ModelContext, not captured in @State.
    private var filteredFoods: [SavedFood] {
        let filtered = searchText.isEmpty
            ? allFoods.filter { !$0.isArchivedInFoodBank }
            : allFoods.filter(matchesSearch)

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
                } else if filteredFoods.isEmpty {
                    // ── Empty state: everything is archived, or search has no matches ──
                    filteredEmptyState
                } else {
                    // ── Food list with search ──
                    foodList
                }
            }
            .navigationTitle("Food Bank")
            .searchable(text: $searchText, prompt: "Search saved foods")
            .toolbar {
                // "+" menu for adding new foods — to the left of the sort button
                ToolbarItem(placement: .topBarTrailing) {
                    addMenu
                }
                // Sort picker in the toolbar
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            // Sheet to log a selected food to the selected day's journal
            .sheet(item: $selectedFood) { food in
                if food.kind == .calculator {
                    NutritionCalculatorBuildView(calculator: food, logDate: logDate)
                } else {
                    LogFoodSheet(food: food, logDate: logDate)
                }
            }
            // Sheet to edit a food's name, brand, macros
            .sheet(item: $foodToEdit) { food in
                if food.kind == .calculator {
                    NutritionCalculatorEditorView(calculator: food)
                } else if food.kind == .composite {
                    CompositeFoodBuilderView(food: food)
                } else {
                    EditFoodSheet(food: food)
                }
            }
            // Sheets launched from the "+" menu.
            .sheet(item: $addSheet) { sheet in
                switch sheet {
                case .aiSearch:
                    AIFoodSearchView(logDate: logDate)
                case .compositeFood:
                    CompositeFoodBuilderView()
                case .nutritionCalculator:
                    NutritionCalculatorLibraryView(logDate: logDate)
                case .openFoodFacts:
                    OpenFoodFactsSearchView(logDate: logDate)
                case .manualEntry:
                    ManualEntryView(defaultDate: logDate)
                case .archive:
                    FoodBankArchiveView(logDate: logDate)
                }
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
                foodRow(food)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func foodRow(_ food: SavedFood) -> some View {
        // Wrap in a Button + .buttonStyle(.plain) — the same pattern that
        // makes DailyLogView swipes silky smooth.
        Button {
            selectedFood = food
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                SavedFoodRowView(food: food)

                if !searchText.isEmpty && food.isArchivedInFoodBank {
                    archiveStatusLine(for: food)
                }
            }
        }
        .buttonStyle(.plain)
        // Trailing swipe (left) — archive/unarchive plus edit; delete lives inside EditFoodSheet.
        .swipeActions(edge: .trailing) {
            if food.isArchivedInFoodBank {
                Button {
                    restore(food)
                } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                }
                .tint(.green)
            } else {
                Button {
                    archive(food)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.gray)
            }

            Button {
                foodToEdit = food
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        // Leading swipe (right) — quick-add shortcut opens the same LogFoodSheet as tapping.
        .swipeActions(edge: .leading) {
            Button {
                selectedFood = food
            } label: {
                Label("Add", systemImage: "plus")
            }
            .tint(.green)
        }
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

    /// Shown when saved foods exist, but none belong in the current visible list.
    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(
                searchText.isEmpty ? "All Foods Archived" : "No Results",
                systemImage: searchText.isEmpty ? "archivebox" : "magnifyingglass"
            )
        } description: {
            Text(searchText.isEmpty
                ? "Archived foods are hidden from the main list but still appear in search and in the Archive sheet."
                : "Try a different food name or brand.")
        }
    }

    // MARK: - Add Menu

    /// "+" toolbar menu with options to add foods via different methods:
    /// scan a label, enter manually, or search the Open Food Facts database.
    private var addMenu: some View {
        Menu {
            // AI Search — Gemini with Google Search grounding
            Button {
                addSheet = .aiSearch
            } label: {
                Label("AI Search", systemImage: "sparkles")
            }

            // Composite Food — build a saved food from snapshot copies of Food Bank items
            Button {
                addSheet = .compositeFood
            } label: {
                Label("Composite Food", systemImage: "square.stack.3d.up")
            }

            // Nutrition Calculator — runtime restaurant/brand builders
            Button {
                addSheet = .nutritionCalculator
            } label: {
                Label("Nutrition Calculator", systemImage: "slider.horizontal.3")
            }

            // Search Open Food Facts — opens the OFF search sheet
            Button {
                addSheet = .openFoodFacts
            } label: {
                Label("Search Open Food Facts", systemImage: "globe.americas")
            }
            // Manual entry — opens the same ManualEntryView used from the radial menu
            Button {
                addSheet = .manualEntry
            } label: {
                Label("Manual Entry", systemImage: "square.and.pencil")
            }
            // Archive — browse foods hidden from the main Food Bank list
            Button {
                addSheet = .archive
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        } label: {
            Image(systemName: "plus")
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

    @ViewBuilder
    private func archiveStatusLine(for food: SavedFood) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox")
            Text(archiveStatusText(for: food))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.leading, 56)
    }

    private func archiveStatusText(for food: SavedFood) -> String {
        if food.archivedAt != nil {
            return "Archived manually"
        }

        return "Auto archived: not logged in over 2 weeks"
    }

    private func matchesSearch(_ food: SavedFood) -> Bool {
        food.name.localizedCaseInsensitiveContains(searchText) ||
        (food.brand?.localizedCaseInsensitiveContains(searchText) ?? false)
    }

    private func archive(_ food: SavedFood) {
        food.archiveForFoodBank()
        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "food_bank_archive")
    }

    private func restore(_ food: SavedFood) {
        food.restoreFromFoodBankArchive()
        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "food_bank_restore")
    }
}

private enum FoodBankAddSheet: Identifiable {
    case aiSearch
    case compositeFood
    case nutritionCalculator
    case openFoodFacts
    case manualEntry
    case archive

    var id: String {
        switch self {
        case .aiSearch: "aiSearch"
        case .compositeFood: "compositeFood"
        case .nutritionCalculator: "nutritionCalculator"
        case .openFoodFacts: "openFoodFacts"
        case .manualEntry: "manualEntry"
        case .archive: "archive"
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
