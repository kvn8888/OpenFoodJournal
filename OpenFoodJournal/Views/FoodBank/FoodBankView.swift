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
    @Environment(ScanService.self) private var scanService
    @Environment(TursoMirrorService.self) private var tursoMirror
    @Environment(UserGoals.self) private var goals

    /// Date to log foods to (passed from DailyLogView when opened via radial menu)
    var logDate: Date = .now

    // ── SwiftData Query: fetches all SavedFood sorted by most recently created ──
    @Query(sort: \SavedFood.createdAt, order: .reverse)
    private var allFoods: [SavedFood]
    @Query private var preferences: [Preferences]

    // ── Local State ───────────────────────────────────────────────
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .lastUsed
    @State private var selectedBrandFilter: FoodBankBrandFilter = .all
    @State private var selectedLog: FoodBankLogSelection?
    @State private var foodToEdit: SavedFood?          // For the edit sheet
    @State private var addSheet: FoodBankAddSheet?
    @State private var areShelfSuggestionsExpanded = true
    @AppStorage(FoodBankEmojiSettings.autoGenerateKey) private var foodIconGenerationEnabled = false
    @AppStorage(FoodBankEmojiSettings.useGeneratedIconImagesKey) private var useGeneratedFoodIconImages = false

    // ── Computed: filter + sort the foods based on search text ────
    // Filters by name and brand (case-insensitive) so users can quickly find a food.
    // Safe to compute here because the result is never held in @State — SwiftData
    // @Model objects must stay owned by the ModelContext, not captured in @State.
    private var filteredFoods: [SavedFood] {
        let visibleFoods = searchText.isEmpty
            ? allFoods.filter { !$0.isArchivedInFoodBank }
            : allFoods.filter(matchesSearch)

        let filtered = visibleFoods.filter {
            FoodBankBrandCatalog.matches($0, filter: selectedBrandFilter)
        }

        switch sortOrder {
        case .lastUsed:
            return filtered.sorted { $0.lastUsedAt > $1.lastUsedAt }
        case .newest:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .alphabetical:
            return filtered.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .brandName:
            return FoodBankBrandCatalog.sortByBrand(filtered)
        case .calories:
            return filtered.sorted { $0.calories > $1.calories }
        }
    }

    private var brandOptions: [FoodBankBrandOption] {
        let candidates = searchText.isEmpty
            ? allFoods.filter { !$0.isArchivedInFoodBank }
            : allFoods.filter(matchesSearch)
        return FoodBankBrandCatalog.options(in: candidates, includeUnbranded: true)
    }

    private var showsResultSummary: Bool {
        !searchText.isEmpty || selectedBrandFilter != .all
    }

    private var shelfRecommendations: [ShelfRecommendation] {
        _ = nutritionStore.changeCount
        guard searchText.isEmpty,
              selectedBrandFilter == .all,
              let preferences = preferences.first else { return [] }

        let log = nutritionStore.fetchLog(for: logDate)
        let entries = log?.safeEntries ?? []
        let current = ShelfNutrition(
            calories: log?.totalCalories ?? 0,
            protein: log?.totalProtein ?? 0,
            fiber: summedMicronutrient("fiber", entries: entries),
            carbs: log?.totalCarbs ?? 0,
            fat: log?.totalFat ?? 0,
            sodium: summedMicronutrient("sodium", entries: entries)
        )
        let configuration = shelfConfiguration(preferences)
        let candidates = allFoods.map { food in
            ShelfFoodCandidate(
                id: food.id,
                name: food.name,
                baseQuantity: food.servingQuantity ?? 1,
                baseUnit: food.servingUnit ?? "serving",
                nutrition: ShelfNutrition(
                    calories: food.calories,
                    protein: food.protein,
                    fiber: normalizedMicronutrient("fiber", in: food.micronutrients),
                    carbs: food.carbs,
                    fat: food.fat,
                    sodium: normalizedMicronutrient("sodium", in: food.micronutrients)
                ),
                isOnShelf: food.isOnShelf,
                isManuallyArchived: food.archivedAt != nil
            )
        }
        return ShelfRecommendationEngine.recommend(
            foods: candidates,
            current: current,
            goals: ShelfNutritionGoals(
                calories: goals.dailyCalories,
                protein: goals.dailyProtein,
                carbs: goals.dailyCarbs,
                fat: goals.dailyFat
            ),
            configuration: configuration,
            rollingWeekContext: shelfRollingWeekContext()
        )
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
                // Brand filter and cleanup
                ToolbarItem(placement: .topBarTrailing) {
                    brandMenu
                }
                // Sort picker in the toolbar
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            // Sheet to log a selected food to the selected day's journal
            .sheet(item: $selectedLog) { selection in
                let food = selection.food
                if food.kind == .calculator, selection.recommendation == nil {
                    NutritionCalculatorBuildView(calculator: food, logDate: logDate)
                } else {
                    LogFoodSheet(
                        food: food,
                        logDate: logDate,
                        initialQuantity: selection.recommendation?.quantity,
                        initialUnit: selection.recommendation?.unit
                    )
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
                case .brandManager:
                    FoodBankBrandManagerView(foods: allFoods) { source, target in
                        if selectedBrandFilter == .brand(source) {
                            selectedBrandFilter = .brand(target)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Food List

    /// The main scrollable list of saved foods, grouped by search results.
    /// Each row is tappable (to log) and swipeable (to delete).
    private var foodList: some View {
        List {
            if showsResultSummary {
                resultSummaryRow
            }

            if !shelfRecommendations.isEmpty {
                Section {
                    if areShelfSuggestionsExpanded {
                        ForEach(shelfRecommendations) { recommendation in
                            if let food = allFoods.first(where: { $0.id == recommendation.foodID }) {
                                Button {
                                    selectedLog = .suggestion(food, recommendation)
                                } label: {
                                    ShelfSuggestionRow(food: food, recommendation: recommendation)
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(recommendation.foodName)
                                .accessibilityValue(
                                    "Recommended \(recommendation.quantityText) \(recommendation.unit). \(recommendation.reason)." +
                                    (recommendation.hasIncompleteNutrition ? " Nutrition incomplete." : "")
                                )
                                .accessibilityHint("Opens an editable food log with the recommended quantity.")
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } header: {
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            areShelfSuggestionsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Shelf Suggestions")
                                    .font(.headline)
                                Text("Good fits from foods you have at home")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(areShelfSuggestionsExpanded ? 180 : 0))
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Shelf Suggestions")
                    .accessibilityValue(areShelfSuggestionsExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Double tap to show or hide food suggestions.")
                }
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
            selectedLog = .standard(food)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                SavedFoodRowView(food: food)

                if !searchText.isEmpty && food.isArchivedInFoodBank {
                    archiveStatusLine(for: food)
                }

                if food.isOnShelf {
                    Label("On Shelf", systemImage: "cabinet.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.leading, 56)
                        .accessibilityLabel("On Shelf: you have this food at home")
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                selectedLog = .standard(food)
            } label: {
                Label("Log Food", systemImage: "plus.circle")
            }

            Button {
                foodToEdit = food
            } label: {
                Label("Edit", systemImage: "pencil")
            }


            Button {
                toggleShelf(food)
            } label: {
                Label(
                    food.isOnShelf ? "Remove from Shelf" : "Add to Shelf",
                    systemImage: food.isOnShelf ? "cabinet.fill" : "cabinet"
                )
            }

            if foodIconGenerationEnabled {
                Button {
                    regenerateFoodIcon(for: food)
                } label: {
                    Label(foodIconActionTitle(for: food), systemImage: useGeneratedFoodIconImages ? "photo.badge.plus" : "sparkles")
                }
            }

            if food.hasGeneratedFoodIconImage {
                Button {
                    pixelPassFoodIcon(for: food)
                } label: {
                    Label("Pixel Pass", systemImage: "wand.and.sparkles")
                }
            }

            if food.isArchivedInFoodBank {
                Button {
                    restore(food)
                } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button {
                    archive(food)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        }
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
                selectedLog = .standard(food)
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
            Text(filteredEmptyDescription)
        }
    }

    private var filteredEmptyDescription: String {
        if !searchText.isEmpty {
            return "Try a different food name, brand, or filter."
        }
        if selectedBrandFilter != .all {
            return "Try another brand filter."
        }
        return "Archived foods are hidden from the main list but still appear in search and in the Archive sheet."
    }

    // MARK: - Add Menu

    /// "+" toolbar menu with options to add foods via different methods:
    /// scan a label, enter manually, or search the Open Food Facts database.
    private var addMenu: some View {
        Menu {
            // AI Search — selected AI provider with web grounding
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

            Divider()

            Button {
                addSheet = .brandManager
            } label: {
                Label("Manage Brands", systemImage: "tag")
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    private func foodIconActionTitle(for food: SavedFood) -> String {
        if useGeneratedFoodIconImages {
            return food.hasGeneratedFoodIconImage ? "Regenerate Image" : "Generate Image"
        }
        return "Regenerate Emoji"
    }

    private func regenerateFoodIcon(for food: SavedFood) {
        Task {
            if useGeneratedFoodIconImages {
                await scanService.generateFoodIconImage(for: food, force: true)
            } else {
                await scanService.refreshFoodEmoji(for: food)
            }
        }
    }

    private func pixelPassFoodIcon(for food: SavedFood) {
        Task {
            await scanService.pixelPassFoodIconImage(for: food)
        }
    }

    // MARK: - Brand Menu

    private var brandMenu: some View {
        Menu {
            Picker("Brand", selection: $selectedBrandFilter) {
                Label("All Brands", systemImage: "tag")
                    .tag(FoodBankBrandFilter.all)
                ForEach(brandOptions) { option in
                    Label(option.menuLabel, systemImage: option.icon)
                        .tag(option.filter)
                }
            }

            Divider()

            Button {
                addSheet = .brandManager
            } label: {
                Label("Manage Brands", systemImage: "tag")
            }
        } label: {
            Image(systemName: selectedBrandFilter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
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

    private var resultSummaryRow: some View {
        HStack(spacing: 8) {
            Text(resultSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if selectedBrandFilter != .all {
                Button("Clear") {
                    selectedBrandFilter = .all
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .listRowBackground(Color.clear)
    }

    private var resultSummaryText: String {
        let countText = "\(filteredFoods.count) result\(filteredFoods.count == 1 ? "" : "s")"
        guard selectedBrandFilter != .all else { return countText }
        return "\(countText) • \(selectedBrandFilter.label)"
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

    private func toggleShelf(_ food: SavedFood) {
        food.isOnShelf.toggle()
        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "food_bank_shelf_changed")
    }

    private func shelfConfiguration(_ preferences: Preferences) -> ShelfRecommendationConfiguration {
        var hardCaps: Set<ShelfNutrient> = []
        if preferences.shelfHardCapCalories { hardCaps.insert(.calories) }
        if preferences.shelfHardCapSodium { hardCaps.insert(.sodium) }

        return ShelfRecommendationConfiguration(
            enabled: preferences.shelfRecommendationsEnabled,
            suggestionCount: preferences.clampedShelfSuggestionCount,
            energyIntent: preferences.shelfEnergyIntent,
            nutritionEmphasis: preferences.shelfNutritionEmphasis,
            triggerFraction: preferences.shelfTriggerFraction,
            incompleteNutritionPolicy: preferences.shelfIncompleteNutritionPolicy,
            useRollingWeekContext: preferences.shelfUseRollingWeekContext,
            hardCaps: hardCaps,
            customPolicies: Dictionary(uniqueKeysWithValues: ShelfNutrient.allCases.map {
                ($0, preferences.shelfPolicy(for: $0))
            }),
            customStrengths: Dictionary(uniqueKeysWithValues: ShelfNutrient.allCases.map {
                ($0, preferences.shelfStrength(for: $0))
            })
        )
    }

    private func shelfRollingWeekContext() -> ShelfRollingWeekContext {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: logDate)
        let priorDayCalories = (1...6).reversed().map { daysAgo -> Double? in
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: selectedDay),
                  let log = nutritionStore.fetchLog(for: date),
                  !log.safeEntries.isEmpty,
                  log.totalCalories > 0 else {
                return nil
            }
            return log.totalCalories
        }
        return ShelfRollingWeekContext(priorDayCalories: priorDayCalories)
    }

    private func summedMicronutrient(_ id: String, entries: [NutritionEntry]) -> Double {
        entries.reduce(0) { total, entry in
            total + (normalizedMicronutrient(id, in: entry.micronutrients) ?? 0)
        }
    }

    private func normalizedMicronutrient(
        _ id: String,
        in micronutrients: [String: MicronutrientValue]
    ) -> Double? {
        guard let value = KnownMicronutrients.value(in: micronutrients, forID: id) else { return nil }
        let unit = value.unit.lowercased()
        if id == "sodium", unit == "g" { return value.value * 1_000 }
        if id == "fiber", unit == "mg" { return value.value / 1_000 }
        return value.value
    }
}

private enum FoodBankLogSelection: Identifiable {
    case standard(SavedFood)
    case suggestion(SavedFood, ShelfRecommendation)

    var food: SavedFood {
        switch self {
        case .standard(let food), .suggestion(let food, _): food
        }
    }

    var recommendation: ShelfRecommendation? {
        guard case .suggestion(_, let recommendation) = self else { return nil }
        return recommendation
    }

    var id: String {
        switch self {
        case .standard(let food): "standard-\(food.id)"
        case .suggestion(let food, _): "suggestion-\(food.id)"
        }
    }
}

private struct ShelfSuggestionRow: View {
    let food: SavedFood
    let recommendation: ShelfRecommendation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
                .frame(width: 28, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(food.name)
                        .font(.body.weight(.medium))
                    Spacer()
                    Text("\(recommendation.quantityText) \(recommendation.unit)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }

                Text(recommendation.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if recommendation.hasIncompleteNutrition {
                    Label("Nutrition incomplete", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
    }
}

private enum FoodBankAddSheet: Identifiable {
    case aiSearch
    case compositeFood
    case nutritionCalculator
    case openFoodFacts
    case manualEntry
    case archive
    case brandManager

    var id: String {
        switch self {
        case .aiSearch: "aiSearch"
        case .compositeFood: "compositeFood"
        case .nutritionCalculator: "nutritionCalculator"
        case .openFoodFacts: "openFoodFacts"
        case .manualEntry: "manualEntry"
        case .archive: "archive"
        case .brandManager: "brandManager"
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
    case brandName
    case calories

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastUsed: "Last Used"
        case .newest: "Newest First"
        case .alphabetical: "A → Z"
        case .brandName: "Brand Name"
        case .calories: "Highest Calories"
        }
    }

    var icon: String {
        switch self {
        case .lastUsed: "clock.arrow.circlepath"
        case .newest: "clock"
        case .alphabetical: "textformat.abc"
        case .brandName: "tag"
        case .calories: "flame"
        }
    }
}

// MARK: - Brand Filtering

enum FoodBankBrandFilter: Hashable {
    case all
    case unbranded
    case brand(String)

    var label: String {
        switch self {
        case .all: "All Brands"
        case .unbranded: "Unbranded"
        case .brand(let brand): brand
        }
    }
}

struct FoodBankBrandOption: Identifiable, Hashable {
    enum Kind: Hashable {
        case unbranded
        case brand(String)
    }

    let kind: Kind
    let count: Int

    var id: String {
        switch kind {
        case .unbranded: "__unbranded"
        case .brand(let name): name
        }
    }

    var name: String {
        switch kind {
        case .unbranded: "Unbranded"
        case .brand(let name): name
        }
    }

    var menuLabel: String {
        "\(name) (\(count))"
    }

    var icon: String {
        switch kind {
        case .unbranded: "tag.slash"
        case .brand: "tag"
        }
    }

    var filter: FoodBankBrandFilter {
        switch kind {
        case .unbranded: .unbranded
        case .brand(let name): .brand(name)
        }
    }
}

enum FoodBankBrandCatalog {
    static func normalizedBrand(_ brand: String?) -> String? {
        guard let trimmed = brand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func options(in foods: [SavedFood], includeUnbranded: Bool) -> [FoodBankBrandOption] {
        var counts: [String: Int] = [:]
        var unbrandedCount = 0

        for food in foods {
            if let brand = normalizedBrand(food.brand) {
                counts[brand, default: 0] += 1
            } else {
                unbrandedCount += 1
            }
        }

        var options = counts
            .map { FoodBankBrandOption(kind: .brand($0.key), count: $0.value) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if order == .orderedSame {
                    return lhs.name.localizedCompare(rhs.name) == .orderedAscending
                }
                return order == .orderedAscending
            }

        if includeUnbranded, unbrandedCount > 0 {
            options.insert(FoodBankBrandOption(kind: .unbranded, count: unbrandedCount), at: 0)
        }

        return options
    }

    static func matches(_ food: SavedFood, filter: FoodBankBrandFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .unbranded:
            return normalizedBrand(food.brand) == nil
        case .brand(let brand):
            return normalizedBrand(food.brand) == normalizedBrand(brand)
        }
    }

    static func sortByBrand(_ foods: [SavedFood]) -> [SavedFood] {
        foods.sorted { lhs, rhs in
            compareByBrand(lhs, rhs)
        }
    }

    static func consolidate(sourceBrand: String, targetBrand: String, in foods: [SavedFood]) -> Int {
        guard let source = normalizedBrand(sourceBrand),
              let target = normalizedBrand(targetBrand),
              source != target else {
            return 0
        }

        var updatedCount = 0
        for food in foods where normalizedBrand(food.brand) == source {
            food.brand = target
            updatedCount += 1
        }
        return updatedCount
    }

    static func count(sourceBrand: String, in foods: [SavedFood]) -> Int {
        guard let source = normalizedBrand(sourceBrand) else { return 0 }
        return foods.filter { normalizedBrand($0.brand) == source }.count
    }

    private static func compareByBrand(_ lhs: SavedFood, _ rhs: SavedFood) -> Bool {
        let lhsBrand = normalizedBrand(lhs.brand)
        let rhsBrand = normalizedBrand(rhs.brand)

        switch (lhsBrand, rhsBrand) {
        case let (left?, right?):
            let brandOrder = left.localizedCaseInsensitiveCompare(right)
            if brandOrder != .orderedSame {
                return brandOrder == .orderedAscending
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }

        return lhs.createdAt > rhs.createdAt
    }
}

private struct FoodBankBrandManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(TursoMirrorService.self) private var tursoMirror

    let foods: [SavedFood]
    let onConsolidate: (String, String) -> Void

    @State private var sourceBrand = ""
    @State private var targetBrand = ""
    @State private var showConfirmation = false

    private var brandOptions: [FoodBankBrandOption] {
        FoodBankBrandCatalog.options(in: foods, includeUnbranded: false)
    }

    private var targetOptions: [FoodBankBrandOption] {
        brandOptions.filter { $0.name != sourceBrand }
    }

    private var affectedCount: Int {
        FoodBankBrandCatalog.count(sourceBrand: sourceBrand, in: foods)
    }

    private var trimmedSource: String {
        sourceBrand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTarget: String {
        targetBrand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConsolidate: Bool {
        !trimmedSource.isEmpty && !trimmedTarget.isEmpty && trimmedSource != trimmedTarget && affectedCount > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                if brandOptions.isEmpty {
                    ContentUnavailableView {
                        Label("No Brands", systemImage: "tag.slash")
                    } description: {
                        Text("Saved foods with brands will appear here.")
                    }
                } else {
                    Section("Source") {
                        Picker("Brand", selection: $sourceBrand) {
                            ForEach(brandOptions) { option in
                                Text(option.menuLabel)
                                    .tag(option.name)
                            }
                        }
                    }

                    Section("Target") {
                        Picker("Existing Brand", selection: $targetBrand) {
                            Text("Custom").tag("")
                            ForEach(targetOptions) { option in
                                Text(option.name)
                                    .tag(option.name)
                            }
                        }

                        TextField("Target brand", text: $targetBrand)
                            .textInputAutocapitalization(.words)
                    }

                    Section {
                        LabeledContent("Foods", value: "\(affectedCount)")
                    }
                }
            }
            .navigationTitle("Manage Brands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Consolidate") {
                        showConfirmation = true
                    }
                    .fontWeight(.semibold)
                    .disabled(!canConsolidate)
                }
            }
            .confirmationDialog(
                "Consolidate Brands?",
                isPresented: $showConfirmation,
                titleVisibility: .visible
            ) {
                Button("Consolidate \(affectedCount) Food\(affectedCount == 1 ? "" : "s")") {
                    consolidate()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(trimmedSource) → \(trimmedTarget)")
            }
            .onAppear(perform: selectDefaultBrands)
        }
    }

    private func selectDefaultBrands() {
        guard sourceBrand.isEmpty, let first = brandOptions.first else { return }
        sourceBrand = first.name
        targetBrand = targetOptions.first?.name ?? ""
    }

    private func consolidate() {
        let source = trimmedSource
        let target = trimmedTarget
        let updated = FoodBankBrandCatalog.consolidate(
            sourceBrand: source,
            targetBrand: target,
            in: foods
        )
        guard updated > 0 else { return }

        try? modelContext.save()
        tursoMirror.scheduleMirror(reason: "food_bank_brand_consolidated")
        onConsolidate(source, target)
        dismiss()
    }
}
