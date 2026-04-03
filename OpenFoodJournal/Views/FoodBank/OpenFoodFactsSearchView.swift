// OpenFoodJournal — OpenFoodFactsSearchView
// Search interface for finding foods in the Open Food Facts database.
// Users type a food name, see results, and can add them to their journal
// and/or Food Bank using the same pattern as ManualEntryView.
//
// Design notes:
// - Debounced search avoids hammering the OFF API (10 req/min limit)
// - Results show product name, brand, and macro summary using MacroChip
// - Tapping a result opens a detail sheet with full nutrition + save options
// - "Add to Journal" / "Add to Journal & Food Bank" matches ManualEntryView pattern
//
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct OpenFoodFactsSearchView: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore
    @Environment(OpenFoodFactsService.self) private var offService

    /// Date to log foods to (passed from the parent view)
    var logDate: Date = .now

    // ── Local State ───────────────────────────────────────────────
    /// The user's search query text
    @State private var searchText = ""
    /// Debounce task — cancelled and re-created on each keystroke
    @State private var searchTask: Task<Void, Never>?
    /// The product selected for detail view / saving
    @State private var selectedProduct: OFFProduct?
    /// Which meal type to assign when logging
    @State private var mealType: MealType = .snack

    var body: some View {
        NavigationStack {
            Group {
                if offService.searchResults.isEmpty && !offService.isLoading && searchText.isEmpty {
                    // Initial state — no search yet
                    emptyPrompt
                } else if offService.searchResults.isEmpty && !offService.isLoading {
                    // Search returned no results
                    noResults
                } else {
                    // Show search results list
                    resultsList
                }
            }
            .navigationTitle("Open Food Facts")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search foods (e.g. greek yogurt)")
            .onChange(of: searchText) { _, newValue in
                debouncedSearch(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            // Detail sheet for selected product — shows nutrition + save buttons
            .sheet(item: $selectedProduct) { product in
                OFFProductDetailSheet(
                    product: product,
                    logDate: logDate,
                    mealType: mealType
                )
            }
            // Show loading indicator in toolbar when fetching
            .overlay {
                if offService.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            // Show error banner if something went wrong
            .overlay(alignment: .bottom) {
                if let error = offService.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.gradient, in: Capsule())
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Empty Prompt

    /// Shown before the user types anything — guides them to search
    private var emptyPrompt: some View {
        ContentUnavailableView {
            Label("Search Open Food Facts", systemImage: "magnifyingglass")
        } description: {
            Text("Search over 4 million products from the open food database.")
        }
    }

    // MARK: - No Results

    /// Shown when a search returns zero matches
    private var noResults: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text("No products found for \"\(searchText)\". Try a different search term.")
        }
    }

    // MARK: - Results List

    /// Scrollable list of OFF search results
    private var resultsList: some View {
        List {
            // Result count header
            if offService.totalResultCount > 0 {
                Text("\(offService.totalResultCount) products found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            // Product rows
            ForEach(offService.searchResults) { product in
                Button {
                    selectedProduct = product
                } label: {
                    OFFProductRow(product: product)
                }
                .buttonStyle(.plain)
            }

            // Meal type picker at the bottom
            Section {
                Picker("Meal", selection: $mealType) {
                    ForEach(MealType.allCases, id: \.self) { meal in
                        Text(meal.rawValue.capitalized).tag(meal)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Log to meal")
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Debounced Search

    /// Cancels any in-flight search and starts a new one after a short delay.
    /// The 0.5s debounce prevents firing a request on every keystroke,
    /// which would quickly exceed OFF's 10 req/min rate limit.
    private func debouncedSearch(_ query: String) {
        // Cancel the previous search task if it hasn't fired yet
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            offService.searchResults = []
            offService.totalResultCount = 0
            return
        }

        // Start a new delayed search
        searchTask = Task {
            // Wait 500ms before actually searching — if the user types another
            // character during this time, this task gets cancelled
            try? await Task.sleep(for: .milliseconds(500))

            // Check if we were cancelled during the sleep
            guard !Task.isCancelled else { return }

            try? await offService.search(query: trimmed)
        }
    }
}

// MARK: - OFFProductRow

/// A single row in the search results list.
/// Shows product name, brand, calories, and macro chips.
struct OFFProductRow: View {
    let product: OFFProduct

    var body: some View {
        HStack(spacing: 12) {
            // Calorie count in a rounded box (matches SavedFoodRowView pattern)
            Text("\(Int(product.caloriesPerServing))")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 50, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                // Brand (if available) — shown in smaller gray text above the name
                if let brand = product.brand {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Product name
                Text(product.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                // Serving size info
                if let serving = product.servingSize {
                    Text(serving)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Macro chips (reuses the same component as EntryRowView)
            VStack(alignment: .trailing, spacing: 2) {
                MacroChip(value: product.proteinPerServing, color: .blue, label: "P")
                MacroChip(value: product.carbsPerServing, color: .orange, label: "C")
                MacroChip(value: product.fatPerServing, color: .red, label: "F")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - OFFProductDetailSheet

/// Detail sheet shown when the user taps a search result.
/// Displays full nutrition info and provides save options matching
/// the ManualEntryView pattern (Add to Journal / Add to Journal & Food Bank).
struct OFFProductDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(NutritionStore.self) private var nutritionStore

    let product: OFFProduct
    var logDate: Date = .now
    var mealType: MealType = .snack

    var body: some View {
        NavigationStack {
            List {
                // Product identity section
                Section {
                    if let brand = product.brand {
                        LabeledContent("Brand", value: brand)
                    }
                    LabeledContent("Product", value: product.name)
                    if let serving = product.servingSize {
                        LabeledContent("Serving Size", value: serving)
                    }
                    if !product.code.isEmpty {
                        LabeledContent("Barcode", value: product.code)
                    }
                }

                // Core macros section — the four main nutrition values
                Section("Nutrition (per serving)") {
                    macroRow("Calories", value: product.caloriesPerServing, unit: "kcal", color: .primary)
                    macroRow("Protein", value: product.proteinPerServing, unit: "g", color: .blue)
                    macroRow("Carbs", value: product.carbsPerServing, unit: "g", color: .orange)
                    macroRow("Fat", value: product.fatPerServing, unit: "g", color: .red)
                }

                // Micronutrients section (if any were parsed from OFF data)
                if !product.micronutrients.isEmpty {
                    Section("Additional Nutrients") {
                        ForEach(product.micronutrients.sorted(by: { $0.key < $1.key }), id: \.key) { name, value in
                            LabeledContent(name, value: "\(String(format: "%.1f", value.value)) \(value.unit)")
                        }
                    }
                }

                // Per-100g reference values for transparency
                Section("Per 100g (reference)") {
                    macroRow("Calories", value: product.caloriesPer100g, unit: "kcal", color: .secondary)
                    macroRow("Protein", value: product.proteinPer100g, unit: "g", color: .secondary)
                    macroRow("Carbs", value: product.carbsPer100g, unit: "g", color: .secondary)
                    macroRow("Fat", value: product.fatPer100g, unit: "g", color: .secondary)
                }

                // Attribution — required by Open Food Facts license
                Section {
                    Link(destination: URL(string: "https://world.openfoodfacts.org/product/\(product.code)")!) {
                        Label("View on Open Food Facts", systemImage: "arrow.up.right.square")
                    }
                    Text("Data provided by Open Food Facts contributors under ODbL.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Product Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Cancel button (left)
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Save menu (right) — same pattern as ManualEntryView
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        // Primary: save to both journal and food bank
                        Button {
                            save(saveToFoodBank: true)
                        } label: {
                            Label("Add to Journal & Food Bank", systemImage: "plus.circle.fill")
                        }
                        // Secondary: log only
                        Button {
                            save(saveToFoodBank: false)
                        } label: {
                            Label("Add to Journal", systemImage: "plus.circle")
                        }
                    } label: {
                        Text("Add")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: - Macro Row Helper

    /// A labeled row showing a nutrient name, value, and unit with color accent
    private func macroRow(_ label: String, value: Double, unit: String, color: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(String(format: "%.1f", value)) \(unit)")
                .foregroundStyle(color)
                .fontWeight(.medium)
        }
    }

    // MARK: - Save

    /// Saves the OFF product to the journal and optionally to the Food Bank.
    /// Mirrors the save flow from ManualEntryView exactly.
    private func save(saveToFoodBank: Bool) {
        // Convert OFF product to a NutritionEntry
        let entry = OpenFoodFactsService.toNutritionEntry(product, mealType: mealType)

        // Log to the selected date's journal
        nutritionStore.log(entry, to: logDate)

        // Optionally save to Food Bank for quick re-logging
        if saveToFoodBank {
            let savedFood = OpenFoodFactsService.toSavedFood(product)
            modelContext.insert(savedFood)
            try? modelContext.save()
        }

        dismiss()
    }
}

// MARK: - OFFProduct Identifiable for .sheet(item:)

/// Makes OFFProduct work with SwiftUI's .sheet(item:) modifier.
/// The binding clears selectedProduct when the sheet dismisses.
extension OFFProduct: Hashable {
    static func == (lhs: OFFProduct, rhs: OFFProduct) -> Bool {
        lhs.code == rhs.code
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(code)
    }
}
