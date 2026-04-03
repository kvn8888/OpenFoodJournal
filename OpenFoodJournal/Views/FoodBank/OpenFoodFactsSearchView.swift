// OpenFoodJournal — OpenFoodFactsSearchView
// Search interface for finding foods in the Open Food Facts database.
// Users type a food name, hit Return to search, and see results styled
// like Food Bank entries with calories, macros, and serving info.
// Tapping a result opens ManualEntryView pre-filled with the product's data.
//
// Design notes:
// - Search fires only on Return/Enter (not per-keystroke) for efficiency
// - Results display full nutrition (batch-fetched after search) in SavedFoodRowView style
// - ManualEntryView is reused for product details so users can edit before saving
//
// AGPL-3.0 License

import SwiftUI
import SwiftData

struct OpenFoodFactsSearchView: View {
    // ── Environment ───────────────────────────────────────────────
    @Environment(\.dismiss) private var dismiss
    @Environment(OpenFoodFactsService.self) private var offService

    /// Date to log foods to (passed from the parent view)
    var logDate: Date = .now

    // ── Local State ───────────────────────────────────────────────
    /// The user's search query text
    @State private var searchText = ""
    /// The product selected to open in ManualEntryView for review/editing
    @State private var selectedProduct: OFFProduct?
    /// Tracks whether the user has performed at least one search
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            Group {
                if offService.searchResults.isEmpty && !offService.isLoading && !hasSearched {
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
            .searchable(text: $searchText, prompt: "Search foods, then press Return")
            // Fire search only when user presses Return/Enter
            .onSubmit(of: .search) {
                performSearch()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            // ManualEntryView sheet — pre-filled with OFF product data for review
            .sheet(item: $selectedProduct) { product in
                ManualEntryView(defaultDate: logDate, prefillProduct: product)
            }
            // Show loading indicator when fetching
            .overlay {
                if offService.isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Fetching nutrition data…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
            Text("Search over 4 million products. Type a food name and press Return.")
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

    /// Scrollable list of OFF search results — styled like Food Bank items
    private var resultsList: some View {
        List {
            // Result count header
            if offService.totalResultCount > 0 {
                Text("\(offService.totalResultCount) products found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            // Product rows — styled like SavedFoodRowView
            ForEach(offService.searchResults) { product in
                Button {
                    selectedProduct = product
                } label: {
                    OFFProductRow(product: product)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Search

    /// Performs a search when the user presses Return/Enter.
    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        hasSearched = true
        Task {
            try? await offService.search(query: trimmed)
        }
    }
}

// MARK: - OFFProductRow

/// A single row displaying an OFF product — matches SavedFoodRowView's layout
/// with calorie count, brand, name, serving size, and macro chips.
struct OFFProductRow: View {
    let product: OFFProduct

    var body: some View {
        HStack(spacing: 12) {
            // ── Left: Calorie count as the primary identifier ──
            VStack(alignment: .center, spacing: 2) {
                Text("\(Int(product.caloriesPerServing))")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("cal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44)

            // ── Center: Food name + serving info ──
            VStack(alignment: .leading, spacing: 2) {
                // Show brand above food name if available
                if let brand = product.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(product.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                // Show serving size if available
                if let serving = product.servingSize {
                    Text(serving)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // ── Right: Macro chips matching SavedFoodRowView ──
            HStack(spacing: 6) {
                MacroChip(value: product.proteinPerServing, color: .blue, label: "P")
                MacroChip(value: product.carbsPerServing, color: .green, label: "C")
                MacroChip(value: product.fatPerServing, color: .yellow, label: "F")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
